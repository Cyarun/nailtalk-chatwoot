# frozen_string_literal: true

# Dispatches the "screener" LiveKit agent into an internal call room so it transcribes the
# caller and streams the reason live to the ringing receiver's card. Runs ~2 rings AFTER
# the callee starts ringing (scheduled with a small wait) so the card rings first, then the
# screener attaches. No-op if the call was already answered/ended by the time it runs.
class Voice::DispatchScreenerJob < ApplicationJob
  queue_as :low

  def perform(call_id)
    call = Call.find_by(id: call_id)
    return unless call && call.status == 'ringing'

    room_name = call.meta['room_name']
    return if room_name.blank?

    host = ENV.fetch('LIVEKIT_URL', '').sub(/^ws/, 'http')
    return if host.blank?

    client = LiveKit::AgentDispatchServiceClient.new(
      host,
      api_key: ENV.fetch('LIVEKIT_API_KEY', nil),
      api_secret: ENV.fetch('LIVEKIT_API_SECRET', nil)
    )
    # create_dispatch(room_name, agent_name, metadata:) — positional per the livekit gem.
    client.create_dispatch(room_name, 'screener')
    Rails.logger.info("[screener] dispatched to internal room #{room_name} (call #{call_id})")
  rescue StandardError => e
    Rails.logger.warn("[screener] dispatch failed for call #{call_id}: #{e.class} #{e.message}")
  end
end
