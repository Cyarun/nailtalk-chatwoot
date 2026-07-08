# frozen_string_literal: true

# Voice::InternalCallBuilder — sets up an internal (agent<->agent or AI<->agent) call over
# a LiveKit room. NO PSTN, NO Vobiz, NO Channel/inbox — just a shared LiveKit room the two
# users join in the browser. Creates a Call (call_kind: internal) for history + fires a
# targeted ring to the callee so their FloatingCallWidget rings.
class Voice::InternalCallBuilder
  pattr_initialize [:account!, :caller_user!, :callee_user!]

  # Raised when the callee is already on a call — the controller renders a "busy" response
  # so the caller isn't double-ringing someone who's already engaged.
  class CalleeBusyError < StandardError; end

  def perform!
    # Serialize the busy-check + create so two simultaneous callers can't both pass the
    # check and double-ring the same callee (read-then-create race). Row-lock on the callee.
    call = nil
    ActiveRecord::Base.transaction do
      callee_user.lock!
      # A user has ONE active call at a time. If the caller has a leftover ringing/in_progress
      # call (they cut off / dropped without a clean hangup), terminate it before starting a new
      # one — otherwise the stale call haunts /active and shows a phantom "rejoin?" prompt.
      terminate_stale_calls_for(caller_user)
      raise CalleeBusyError if callee_busy?

      call = build_and_ring
    end
    call
  end

  private

  # End any live call the given user is still a party to (caller or callee) — used to clear a
  # stale/abandoned call so it can't ghost the next one.
  def terminate_stale_calls_for(user)
    account.calls
           .where(call_kind: 'internal', status: %i[ringing in_progress])
           .where('accepted_by_agent_id = :id OR callee_user_id = :id', id: user.id)
           .find_each { |c| c.update!(status: :no_answer) }
  end

  def build_and_ring
    room_name = "nailtalk-internal-#{SecureRandom.hex(6)}"
    call = Call.create!(
      account: account,
      caller_user: caller_user,
      callee_user: callee_user,
      provider: :livekit,
      call_kind: "internal",
      direction: :outgoing,
      status: "ringing",
      provider_call_id: room_name,
      meta: { "room_name" => room_name, "initiated_at" => Time.zone.now.to_i,
              "caller_name" => caller_user.name, "callee_name" => callee_user.name }
    )
    ring_callee(call, room_name)
    # Ring first (~2 rings), THEN attach the screener so it transcribes the caller and
    # streams the reason live to the ringing receiver's card. Delayed so the card rings
    # before the screener joins; the job no-ops if the call is already answered/ended.
    Voice::DispatchScreenerJob.set(wait: 4.seconds).perform_later(call.id)
    # Backstop: if nobody answers and the screener never fires a timeout (dispatch failed,
    # env missing), force the call to no_answer so it doesn't stay "ringing" forever and
    # permanently trip callee_busy? for this callee.
    Voice::ExpireRingingCallJob.set(wait: 50.seconds).perform_later(call.id)
    call
  end

  # Is the callee already on a call? Session state across the system: a user has one call
  # at a time. We check for any live Call (ringing/in_progress) they're a party to, so the
  # system doesn't double-ring someone who's already engaged.
  def callee_busy?
    # caller_user is aliased onto accepted_by_agent_id (see Call model), so query that
    # real column — caller_user_id is not a database column.
    account.calls
           .where(status: %i[ringing in_progress])
           .where('accepted_by_agent_id = :id OR callee_user_id = :id', id: callee_user.id)
           .exists?
  end

  # Broadcast a targeted ring ONLY to the callee (their own pubsub_token stream) so their
  # FloatingCallWidget shows an incoming internal call.
  def ring_callee(call, room_name)
    payload = {
      # account_id is REQUIRED — the frontend's isAValidEvent drops any event whose
      # account_id doesn't match the current account (silently, no ring otherwise).
      account_id: account.id,
      callSid: room_name, roomName: room_name, provider: "livekit",
      callDirection: "inbound", callKind: "internal", callId: call.id,
      caller: { id: caller_user.id, name: caller_user.name }
    }
    ActionCableBroadcastJob.perform_later([callee_user.pubsub_token], "internal_call.ringing", payload)
  end
end
