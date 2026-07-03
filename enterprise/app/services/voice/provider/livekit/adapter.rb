# frozen_string_literal: true

# Voice::Provider::Livekit::Adapter — outbound dial via LiveKit -> Vobiz (PHASE 2).
# Inbound-first: this is referenced by Channel::TwilioSms#initiate_call for the livekit
# provider but not exercised until outbound-to-contact is built. Minimal placeholder so
# the reference resolves; real create_sip_participant (server-sdk-ruby) lands in phase 2.
class Voice::Provider::Livekit::Adapter
  def initialize(channel)
    @channel = channel
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    Rails.logger.info("[livekit-adapter] outbound dial requested to=#{to} (phase 2 - not yet implemented)")
    { provider: "livekit", status: "not_implemented", call_direction: "outbound", agent_id: agent_id }
  end
end
