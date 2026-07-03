# NailTalk — native Meta Lead Ads (Instant Form) webhook receiver.
#
# Replaces the standalone leadgen_bridge.py (:8142) side-car with a first-class Chatwoot
# controller. Meta POSTs a `leadgen` change here when a lead submits an Instant Form; we verify
# the X-Hub-Signature-256 (reusing MetaTokenVerifyConcern, same as the WhatsApp/Instagram
# webhooks) and enqueue Nt::MetaLeadgenJob to fetch the field data and build a native Contact +
# Conversation (with consent + provenance) — no Python, no external process.
#
# Meta sends only IDs in the webhook (leadgen_id/form_id/page_id/ad_id/created_time); the actual
# name/phone/email is fetched by the job via GET /{leadgen_id} with the system-user token.
#
# Routes (config/routes.rb, beside the other webhooks):
#   get  'webhooks/meta_leadgen' -> #verify   (Meta subscription challenge)
#   post 'webhooks/meta_leadgen' -> #events    (leadgen notifications)
#
# Config (InstallationConfig, reused from the existing Meta app):
#   FB_APP_SECRET   — HMAC key for X-Hub-Signature-256
#   FB_VERIFY_TOKEN — the subscription verify-token string set in the App Dashboard
class Webhooks::MetaLeadgenController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :events

  # GET — Meta subscription verification handshake. MetaTokenVerifyConcern#verify echoes
  # hub.challenge when hub.verify_token matches (valid_token? below).
  def verify
    if valid_token?(params['hub.verify_token'])
      Rails.logger.info('[meta-leadgen] webhook verified')
      render json: params['hub.challenge']
    else
      render status: :unauthorized, json: { error: 'Error; wrong verify token' }
    end
  end

  # POST — a lead was submitted. For each `leadgen` change, enqueue a job to fetch + ingest it.
  # Respond 200 fast (Meta retries on non-2xx); all real work is async in the job.
  def events
    Array(params[:entry]).each do |entry|
      Array(entry[:changes]).each do |change|
        next unless change[:field] == 'leadgen'

        value = change[:value] || {}
        leadgen_id = value[:leadgen_id]
        next if leadgen_id.blank?

        Nt::MetaLeadgenJob.perform_later(
          leadgen_id: leadgen_id.to_s,
          form_id: value[:form_id].to_s,
          page_id: value[:page_id].to_s,
          ad_id: value[:ad_id].to_s,
          created_time: value[:created_time]
        )
      end
    end
    head :ok
  end

  private

  # MetaTokenVerifyConcern hook — the HMAC key(s). Reuse the existing Meta app secret.
  def meta_app_secrets
    [GlobalConfigService.load('FB_APP_SECRET', nil)].compact
  end

  # MetaTokenVerifyConcern hook — verify the subscription token against our configured value.
  def valid_token?(token)
    expected = GlobalConfigService.load('FB_VERIFY_TOKEN', nil)
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
  end
end
