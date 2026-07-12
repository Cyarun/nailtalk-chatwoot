# frozen_string_literal: true

# Nt::WhatsappCatalogueJob (nt-0exh) — sends NailTalk's service catalogue to a customer on
# WhatsApp as native interactive LIST messages, using the inbox's own Cloud API token
# (provider_config['api_key']). Runs in Sidekiq with full DB access — no rails-runner.
#
# Actions:
#   'menu'                       -> Tier 1 category menu (the "catalogue")
#   'list'  + group_id [+ page]  -> Tier 2 a category's service list
#   'reply' + reply_id           -> Tier 2/3 from an incoming list_reply tap (sub-list OR booking link)
#
# Fires when: (a) a customer asks to see the menu/services/prices (Aria/automation enqueues
# 'menu'), or (b) a list_reply tap arrives on the WhatsApp webhook (incoming handler enqueues
# 'reply'). Free-form interactive messages require an open 24h window — the customer just
# messaged, so the window is open by construction for the tap path.
module Nt
  class WhatsappCatalogueJob < ApplicationJob
    queue_as :default

    def perform(inbox_id:, to:, action: 'menu', group_id: nil, page: 0, reply_id: nil)
      inbox = Inbox.find_by(id: inbox_id)
      channel = inbox&.channel
      return log_skip("no whatsapp channel for inbox #{inbox_id}") unless channel.respond_to?(:provider_config)

      cfg = channel.provider_config || {}
      token = cfg['api_key']
      phone_id = cfg['phone_number_id']
      return log_skip('missing token/phone_id') if token.blank? || phone_id.blank?

      payload = build_payload(action, to, group_id, page, reply_id)
      return log_skip("no payload for action=#{action} group=#{group_id} reply=#{reply_id}") if payload.nil?

      post(phone_id, token, payload, action, to)
    rescue StandardError => e
      Rails.logger.error("[wa-catalogue] error to #{to}: #{e.class}: #{e.message}")
    end

    private

    def build_payload(action, to, group_id, page, reply_id)
      case action.to_s
      when 'menu'  then Nt::WhatsappCatalogue.category_menu_payload(to)
      when 'list'  then Nt::WhatsappCatalogue.service_list_payload(to, group_id, page.to_i)
      when 'reply' then Nt::WhatsappCatalogue.payload_for_reply(to, reply_id)
      end
    end

    def post(phone_id, token, payload, action, to)
      resp = HTTParty.post(
        "https://graph.facebook.com/v21.0/#{phone_id}/messages",
        headers: { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' },
        body: payload.to_json,
        timeout: 15
      )
      if resp.success?
        Rails.logger.info("[wa-catalogue] sent action=#{action} to #{to} (msg #{resp.parsed_response.dig('messages', 0, 'id')})")
      else
        Rails.logger.warn("[wa-catalogue] FAILED action=#{action} to #{to} HTTP #{resp.code}: #{resp.body.to_s[0..300]}")
      end
    end

    def log_skip(reason)
      Rails.logger.warn("[wa-catalogue] skipped: #{reason}")
    end
  end
end
