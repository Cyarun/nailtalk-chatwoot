# frozen_string_literal: true

# Nt::ReceptionistNotifyJob (nt-woi5) — sends a conversation-summary WhatsApp to a branch
# receptionist's own WhatsApp number so a REAL human picks up a conversation Aria couldn't
# resolve (instead of dead-ending into the unstaffed in-CRM handoff void).
#
# Uses the WhatsApp inbox's own Cloud API token. Free-form text works only if the receptionist
# messaged the business within 24h; otherwise Meta will reject (131047/24h-window) — in that
# case a pre-approved utility template (staff_lead_alert exists, APPROVED) should be used.
# This first cut sends free-form + logs the result so we can see delivery; template fallback
# is the follow-up.
module Nt
  class ReceptionistNotifyJob < ApplicationJob
    queue_as :default

    def perform(inbox_id:, to:, text:)
      inbox = Inbox.find_by(id: inbox_id)
      channel = inbox&.channel
      return log_skip("no whatsapp channel for inbox #{inbox_id}") unless channel.respond_to?(:provider_config)

      cfg = channel.provider_config || {}
      token = cfg['api_key']
      phone_id = cfg['phone_number_id']
      return log_skip('missing token/phone_id') if token.blank? || phone_id.blank?

      resp = HTTParty.post(
        "https://graph.facebook.com/v21.0/#{phone_id}/messages",
        headers: { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' },
        body: { messaging_product: 'whatsapp', to: to, type: 'text', text: { body: text } }.to_json,
        timeout: 15
      )

      if resp.success?
        Rails.logger.info("[receptionist-notify] sent to #{to} (msg #{resp.parsed_response.dig('messages', 0, 'id')})")
      else
        # Likely the 24h-window (needs a template). Log so we add the staff_lead_alert template fallback.
        Rails.logger.warn("[receptionist-notify] FAILED to #{to} HTTP #{resp.code}: #{resp.body.to_s[0..200]}")
      end
    rescue StandardError => e
      Rails.logger.error("[receptionist-notify] error to #{to}: #{e.message}")
    end

    private

    def log_skip(reason)
      Rails.logger.warn("[receptionist-notify] skipped: #{reason}")
    end
  end
end
