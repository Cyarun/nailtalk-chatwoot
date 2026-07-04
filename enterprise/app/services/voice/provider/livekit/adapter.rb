# frozen_string_literal: true

# Voice::Provider::Livekit::Adapter — REAL outbound dial via LiveKit -> Vobiz.
# Used for outbound / callback: an agent calls a contact (or calls a missed caller back).
# It creates a LiveKit room and dials the destination number through the Vobiz OUTBOUND
# SIP trunk (create_sip_participant). The agent then joins the same room (browser, via a
# LiveKit token) to talk. NOT a stub — this places a real phone call.
class Voice::Provider::Livekit::Adapter
  # Vobiz outbound trunk (976b191f.sip.vobiz.ai), configured in LiveKit as this trunk id.
  OUTBOUND_TRUNK_ID = ENV.fetch("LIVEKIT_OUTBOUND_TRUNK_ID", "ST_RtGmoMisPygE")

  def initialize(channel)
    @channel = channel
  end

  # Dial `to` (E.164) via Vobiz. Returns the room + participant so the caller (agent) can
  # join the same room to talk. requires_agent_join: the browser must join to complete it.
  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    room_name = "nailtalk-out-#{SecureRandom.hex(6)}"
    identity = "sip_out_#{to.to_s.gsub(/\D/, '')}"

    info = sip_client.create_sip_participant(
      OUTBOUND_TRUNK_ID,
      to,
      room_name,
      participant_identity: identity,
      participant_name: to,
      play_dialtone: true,
      wait_until_answered: false
    )

    {
      provider: "livekit",
      status: "ringing",
      call_direction: "outbound",
      room_name: room_name,
      participant_identity: identity,
      requires_agent_join: true,
      agent_id: agent_id,
      sip_call_id: (info.respond_to?(:sip_call_id) ? info.sip_call_id : room_name)
    }
  rescue StandardError => e
    Rails.logger.error("[livekit-adapter] outbound dial to=#{to} failed: #{e.class} #{e.message}")
    { provider: "livekit", status: "failed", call_direction: "outbound", error: e.message, agent_id: agent_id }
  end

  private

  def sip_client
    LiveKit::SIPServiceClient.new(
      ENV.fetch("LIVEKIT_URL", "").sub(/^ws/, "http"),
      api_key: ENV.fetch("LIVEKIT_API_KEY", nil),
      api_secret: ENV.fetch("LIVEKIT_API_SECRET", nil)
    )
  end
end
