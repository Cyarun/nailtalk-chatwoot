# frozen_string_literal: true

# Voice::InternalCallBuilder — sets up an internal (agent<->agent or AI<->agent) call over
# a LiveKit room. NO PSTN, NO Vobiz, NO Channel/inbox — just a shared LiveKit room the two
# users join in the browser. Creates a Call (call_kind: internal) for history + fires a
# targeted ring to the callee so their FloatingCallWidget rings.
class Voice::InternalCallBuilder
  pattr_initialize [:account!, :caller_user!, :callee_user!]

  def perform!
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

  # Broadcast a targeted ring ONLY to the callee (their own pubsub_token stream) so their
  # FloatingCallWidget shows an incoming internal call.
  def ring_callee(call, room_name)
    payload = {
      callSid: room_name, roomName: room_name, provider: "livekit",
      callDirection: "inbound", callKind: "internal", callId: call.id,
      caller: { id: caller_user.id, name: caller_user.name }
    }
    ActionCableBroadcastJob.perform_later([callee_user.pubsub_token], "internal_call.ringing", payload)
  end
end
