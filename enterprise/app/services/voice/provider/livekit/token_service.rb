# frozen_string_literal: true

# Voice::Provider::Livekit::TokenService — mints a LiveKit access token so an agent's
# browser can JOIN the caller's LiveKit room and talk (human-first: agent answers, the
# caller is pulled to / shared with the agent). Mirrors the Twilio TokenService interface
# (inbox:/user:/account: + #generate) but returns a LiveKit join token instead of a
# Twilio JWT. The frontend LiveKitVoiceClient uses { token, livekit_url, room_name } to
# Room.connect() and publish the mic.
class Voice::Provider::Livekit::TokenService
  pattr_initialize [:inbox!, :user!, :account!, { room_name: nil }]

  def generate
    token = LiveKit::AccessToken.new(api_key: api_key, api_secret: api_secret)
    token.identity = identity
    token.name = user.name
    token.video_grant = LiveKit::VideoGrant.new(
      roomJoin: true,
      room: room_name,
      canPublish: true,
      canSubscribe: true
    )

    {
      token: token.to_jwt,
      livekit_url: livekit_ws_url,
      room_name: room_name,
      identity: identity,
      provider: "livekit",
      voice_enabled: true,
      account_id: account.id,
      inbox_id: inbox.id,
      agent_id: user.id
    }
  end

  private

  def identity
    "agent-#{user.id}-account-#{account.id}"
  end

  def api_key
    ENV.fetch("LIVEKIT_API_KEY", nil)
  end

  def api_secret
    ENV.fetch("LIVEKIT_API_SECRET", nil)
  end

  # Browser needs the ws(s):// URL. LIVEKIT_URL is the internal ws://; expose the public
  # wss:// via LIVEKIT_WS_PUBLIC_URL when the agent connects from outside.
  def livekit_ws_url
    ENV["LIVEKIT_WS_PUBLIC_URL"].presence || ENV.fetch("LIVEKIT_URL", nil)
  end
end
