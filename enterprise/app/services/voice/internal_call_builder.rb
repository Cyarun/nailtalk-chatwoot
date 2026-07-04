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
    raise CalleeBusyError if callee_busy?

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
    call
  end

  private

  # Is the callee already on a call? Session state across the system: a user has one call
  # at a time. We check for any live Call (ringing/in_progress) they're a party to, so the
  # system doesn't double-ring someone who's already engaged.
  def callee_busy?
    account.calls
           .where(status: %i[ringing in_progress])
           .where('caller_user_id = :id OR callee_user_id = :id', id: callee_user.id)
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
