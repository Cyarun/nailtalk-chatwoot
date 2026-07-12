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
    norm = message_history.map do |m|
      { role: (m[:role] || m['role']).to_s, content: (m[:content] || m['content']).to_s }
    end.reject { |m| m[:content].strip.empty? }

    last_user = norm.reverse.find { |m| m[:role] == 'user' }
    text = last_user ? last_user[:content].strip : ''
    # History = everything BEFORE the last user message (so Aria has memory; nt-xesy).
    prior = last_user ? norm[0...norm.rindex(last_user)] : norm

    Rails.logger.info("[flue-bridge] cid=#{cid} assistant=#{@assistant.id} conv=#{@conversation&.display_id} msg_len=#{text.length} history=#{prior.length}")

    if text.blank?
      Rails.logger.warn("[flue-bridge] cid=#{cid} empty user message -> handoff")
      return handoff_response('flue_empty_message')
    end

    result = call_flue(text, prior, customer_name, cid)
    return handoff_response('flue_error') if result.nil?

    build_response(result, cid)
  end

  # The known customer's name (so Aria can address a returning customer), if resolvable.
  def customer_name
    @conversation&.contact&.name.presence
  end

  private

  def flue_url
    ENV.fetch('FLUE_URL', DEFAULT_FLUE_URL)
  end

  # Mirror the fork's outbound-HTTP pattern (app/jobs/nt/meta_leadgen_job.rb HTTParty +
  # timeout + success/rescue). HTTParty (not SafeFetch — SafeFetch blocks the private
  # 172.17.0.1 docker-gateway target by design).
  def call_flue(text, history, cust_name, cid)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    payload = { message: text, history: history }
    payload[:customerName] = cust_name if cust_name.present?
    resp = HTTParty.post(
      flue_url,
      body: payload.to_json,
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
  # Branch receptionist WhatsApp numbers — a REAL human picks up the conversation from their
  # own WhatsApp (the in-CRM 'Nail Talk Support' agent is unstaffed, so the old
  # 'conversation_handoff' dead-ended). Digits only, E.164 (no +).
  RECEPTIONIST_WA = {
    'film nagar' => '919177513377',
    'kokapet' => '917330677726',
    'jubilee hills' => '919550890419',
    'banjara hills' => '919390749558'
  }.freeze
  DEFAULT_RECEPTIONIST_WA = ENV.fetch('DEFAULT_RECEPTIONIST_WA', '919550890419') # Jubilee Hills

  # When Aria cannot resolve it herself (needsHuman / error / booking-claim), DO NOT dead-end
  # into the unstaffed in-CRM void. Instead (nt-woi5, user directive): (1) keep the CUSTOMER
  # warm with a helpful services link, and (2) notify the branch RECEPTIONIST on THEIR WhatsApp
  # with a conversation summary so a real person picks it up. Returns a normal reply the bridge
  # sends to the customer — NOT a conversation_handoff token.
  def handoff_response(reason)
    notify_receptionist(reason)
    {
      'response' => "I'd love to make sure you get exactly what you need, so I'm connecting you " \
                    "with our team who will reach out shortly. Meanwhile you can browse all our " \
                    "services and book directly here: https://nailtalk.in/services 💅",
      'needsHuman' => false,
      'action_reason' => reason
    }
  rescue StandardError => e
    Rails.logger.error("[flue-bridge] handoff_response failed: #{e.message}")
    { 'response' => 'conversation_handoff', 'action_reason' => reason }
  end

  # Send a short conversation summary to the branch receptionist's WhatsApp (async, best-effort).
  def notify_receptionist(reason)
    to = receptionist_number
    return if to.blank?

    contact = @conversation&.contact
    last_msgs = @conversation&.messages&.where(message_type: :incoming)&.order(:created_at)&.last(3)&.map { |m| m.content.to_s[0, 80] }&.join(' | ')
    summary = "🔔 Nail Talk lead needs you (#{reason}).\n" \
              "Customer: #{contact&.name} #{contact&.phone_number}\n" \
              "Recent: #{last_msgs}\n" \
              "Open in CRM conv ##{@conversation&.display_id}. Please reply to the customer."

    Rails.logger.info("[flue-bridge] notifying receptionist #{to} for conv=#{@conversation&.display_id} reason=#{reason}")
    ::Nt::ReceptionistNotifyJob.perform_later(inbox_id: @conversation&.inbox_id, to: to, text: summary)
  rescue StandardError => e
    Rails.logger.warn("[flue-bridge] notify_receptionist failed: #{e.message}")
  end

  def receptionist_number
    branch = (@conversation&.custom_attributes&.dig('preferred_branch') ||
              @conversation&.contact&.custom_attributes&.dig('preferred_branch')).to_s.downcase.strip
    RECEPTIONIST_WA[branch] || DEFAULT_RECEPTIONIST_WA
  end

  def truthy?(val)
    val == true || val.to_s.downcase == 'true'
  end
end
