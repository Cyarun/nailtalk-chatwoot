# frozen_string_literal: true

# Captain::FlueBridgeService (nt-x6vk) — routes an assistant's reasoning turn to the
# external Flue T1 reasoning service over HTTP instead of Chatwoot's built-in LLM.
#
# PROTOTYPE + feature-flagged: only runs when the assistant's config has
# reasoning_backend == 'flue' (set on UAT Aria id 1 only; prod assistants stay {}).
# Purpose: measure the full text-path latency (incl. this HTTP hop) and prove the
# integration end-to-end. See MEASURED-flue-latency-verdict memory (~4-6s/turn).
#
# Flue contract (verified in smoke test):
#   POST {FLUE_URL}   body {"message": "<last user msg>"}   (?wait=result held on URL)
#   -> 200 { "result": { reply, needsHuman, claimsBooking, mentionedPrice }, "runId": ... }
#
# Returns a Hash in the SAME shape Captain::Conversation::ResponseBuilderJob#process_response
# consumes, so send / handoff / usage-increment all work with zero downstream changes:
#   - happy path        -> { 'response' => reply, 'agent_name' => assistant.name }
#   - needsHuman         -> { 'response' => 'conversation_handoff', ... }  (legacy v1 handoff token)
#   - claimsBooking      -> handoff too (never auto-send an unverified booking confirmation)
#   - flue error / nil   -> handoff (degrade to a human, never drop the customer)
class Captain::FlueBridgeService
  DEFAULT_FLUE_URL = 'http://172.17.0.1:3583/workflows/aria?wait=result'
  # Generous on purpose — this is a latency-measurement prototype, not a tuned path.
  FLUE_TIMEOUT_SECONDS = ENV.fetch('FLUE_TIMEOUT_SECONDS', '60').to_i

  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
  end

  # message_history = [{ content:, role: ('user'|'assistant'), agent_name? }, ...]
  def generate_response(message_history: [])
    cid = SecureRandom.uuid
    last_user = message_history.reverse.find { |m| m[:role] == 'user' || m['role'] == 'user' }
    text = (last_user && (last_user[:content] || last_user['content'])).to_s.strip

    Rails.logger.info("[flue-bridge] cid=#{cid} assistant=#{@assistant.id} conv=#{@conversation&.display_id} msg_len=#{text.length}")

    if text.blank?
      Rails.logger.warn("[flue-bridge] cid=#{cid} empty user message -> handoff")
      return handoff_response('flue_empty_message')
    end

    result = call_flue(text, cid)
    return handoff_response('flue_error') if result.nil?

    build_response(result, cid)
  end

  private

  def flue_url
    ENV.fetch('FLUE_URL', DEFAULT_FLUE_URL)
  end

  # Mirror the fork's outbound-HTTP pattern (app/jobs/nt/meta_leadgen_job.rb HTTParty +
  # timeout + success/rescue). HTTParty (not SafeFetch — SafeFetch blocks the private
  # 172.17.0.1 docker-gateway target by design).
  def call_flue(text, cid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.post(
      flue_url,
      body: { message: text }.to_json,
      headers: { 'Content-Type' => 'application/json' },
      timeout: FLUE_TIMEOUT_SECONDS
    )
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    unless resp.success?
      Rails.logger.error("[flue-bridge] cid=#{cid} HTTP #{resp.code} (#{elapsed_ms}ms): #{resp.body.to_s[0..300]}")
      return nil
    end

    result = resp.parsed_response.is_a?(Hash) ? resp.parsed_response['result'] : nil
    Rails.logger.info("[flue-bridge] cid=#{cid} OK #{elapsed_ms}ms needsHuman=#{result&.dig('needsHuman')} claimsBooking=#{result&.dig('claimsBooking')} mentionedPrice=#{result&.dig('mentionedPrice')}")
    result
  rescue StandardError => e
    Rails.logger.error("[flue-bridge] cid=#{cid} error: #{e.class}: #{e.message}")
    nil
  end

  # Map Flue's gate signals onto the exact Hash keys process_response reads.
  def build_response(result, cid)
    reply = result['reply'].to_s.strip

    if truthy?(result['needsHuman'])
      Rails.logger.info("[flue-bridge] cid=#{cid} gate=needsHuman -> handoff")
      return handoff_response('flue_needs_human')
    end

    # Never auto-send an unverified booking confirmation — hand to a human to confirm.
    if truthy?(result['claimsBooking'])
      Rails.logger.info("[flue-bridge] cid=#{cid} gate=claimsBooking (no deposit verify in prototype) -> handoff")
      return handoff_response('flue_claims_booking')
    end

    if reply.blank?
      Rails.logger.warn("[flue-bridge] cid=#{cid} blank reply -> handoff")
      return handoff_response('flue_blank_reply')
    end

    { 'response' => reply, 'agent_name' => @assistant.name }
  end

  # The legacy v1 handoff token process_response routes to process_v1_handoff
  # (create_handoff_message + bot_handoff! + OOO). No new handoff logic.
  def handoff_response(reason)
    { 'response' => 'conversation_handoff', 'action_reason' => reason }
  end

  def truthy?(val)
    val == true || val.to_s.downcase == 'true'
  end
end
