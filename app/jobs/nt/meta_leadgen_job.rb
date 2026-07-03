# NailTalk — native ingestion of a Meta Lead Ads submission into a Chatwoot Contact + Conversation.
#
# Enqueued by Webhooks::MetaLeadgenController for each `leadgen` change. Fetches the lead's field
# data from the Graph API, maps identity + consent + provenance, and creates a native Contact (via
# ContactInboxWithContactBuilder — the same builder the FB/IG channels use) + a Conversation, plus
# an immutable Contact note capturing the raw consent/provenance payload (DPDPA-defensible).
#
# Replaces leadgen_bridge.py — all native Rails, no external process.
#
# Config (InstallationConfig):
#   NT_META_LEADGEN_TOKEN   — system-user (or long-lived page) token with leads_retrieval.
#   FACEBOOK_API_VERSION    — Graph API version (default v21.0), reused from the existing config.
#   NT_LEADGEN_INBOX_ID     — target inbox for the lead's ContactInbox/Conversation (default: the
#                             inbox named "Leads").
#
# Idempotent: a Contact custom_attribute `lead_leadgen_id` dedupes repeat webhook deliveries.
class Nt::MetaLeadgenJob < ApplicationJob
  queue_as :low

  DEFAULT_API_VERSION = 'v21.0'.freeze
  GRAPH_HOST = 'https://graph.facebook.com'.freeze

  def perform(leadgen_id:, form_id: nil, page_id: nil, ad_id: nil, created_time: nil)
    token = GlobalConfigService.load('NT_META_LEADGEN_TOKEN', nil)
    if token.blank?
      Rails.logger.warn('[meta-leadgen] NT_META_LEADGEN_TOKEN not set — cannot fetch lead; skipping')
      return
    end

    return if already_ingested?(leadgen_id)

    lead = fetch_lead(leadgen_id, token)
    return if lead.blank?

    fields = extract_field_data(lead['field_data'])
    consent = extract_consent(lead['custom_disclaimer_responses'])
    attrs = build_custom_attributes(lead, fields, consent, form_id: form_id, ad_id: ad_id,
                                                                created_time: created_time)

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: leadgen_inbox,
      source_id: "meta_lead_#{leadgen_id}",
      contact_attributes: {
        name: fields[:full_name].presence || 'Meta Lead',
        phone_number: normalize_phone(fields[:phone_number]),
        email: fields[:email],
        custom_attributes: attrs
      }
    ).perform

    # The builder only applies custom_attributes when it CREATES a contact; a returning lead
    # (matched by phone/email) comes back untouched. Merge our consent/provenance/dedup attrs onto
    # the contact either way so returning leads get fresh provenance AND the dedup key is always set.
    contact = contact_inbox.contact
    contact.update!(custom_attributes: contact.custom_attributes.merge(attrs))

    # ConversationBuilder#conversation_params calls .permit! on custom/additional attributes, so it
    # needs ActionController::Parameters, not a plain Hash.
    conversation = ConversationBuilder.new(
      params: ActionController::Parameters.new(
        custom_attributes: { lead_branch: attrs['lead_branch'] }.compact
      ),
      contact_inbox: contact_inbox
    ).perform

    write_consent_note(contact, lead, consent)
    Rails.logger.info("[meta-leadgen] ingested lead #{leadgen_id} -> contact #{contact.id} conv #{conversation&.display_id}")
    conversation
  end

  private

  def already_ingested?(leadgen_id)
    Contact.where("custom_attributes ->> 'lead_leadgen_id' = ?", leadgen_id.to_s).exists?
  end

  def api_version
    GlobalConfigService.load('FACEBOOK_API_VERSION', nil).presence || DEFAULT_API_VERSION
  end

  def fetch_lead(leadgen_id, token)
    fields = 'field_data,custom_disclaimer_responses,ad_id,ad_name,campaign_id,campaign_name,' \
             'form_id,is_organic,platform,created_time'
    resp = HTTParty.get("#{GRAPH_HOST}/#{api_version}/#{leadgen_id}",
                        query: { access_token: token, fields: fields }, timeout: 20)
    return resp.parsed_response if resp.success?

    Rails.logger.error("[meta-leadgen] GET /#{leadgen_id} failed: #{resp.code} #{resp.body}")
    nil
  rescue StandardError => e
    Rails.logger.error("[meta-leadgen] fetch error for #{leadgen_id}: #{e.class}: #{e.message}")
    nil
  end

  # field_data = [{ name: 'full_name', values: ['Jane'] }, ...] -> symbol-keyed first-value hash
  def extract_field_data(field_data)
    Array(field_data).each_with_object({}) do |f, acc|
      key = f['name'].to_s.to_sym
      acc[key] = Array(f['values']).first
    end
  end

  # custom_disclaimer_responses = [{ checkbox_key:, is_checked: }] — the consent record.
  def extract_consent(responses)
    list = Array(responses)
    checked = list.find { |r| r['is_checked'] } || list.first
    {
      given: list.any? { |r| r['is_checked'] },
      checkbox_key: checked && checked['checkbox_key'],
      raw: list
    }
  end

  def build_custom_attributes(lead, fields, consent, form_id:, ad_id:, created_time:)
    branch = infer_branch(fields)
    {
      'lead_source' => 'meta_lead_ad',
      'lead_leadgen_id' => (lead['id'] || '').to_s,
      'lead_platform' => lead['platform'] || (lead['is_organic'] ? 'organic' : 'paid'),
      'lead_form_id' => (lead['form_id'] || form_id).to_s,
      'lead_campaign_name' => lead['campaign_name'],
      'lead_ad_id' => (lead['ad_id'] || ad_id).to_s,
      'lead_ad_name' => lead['ad_name'],
      'lead_created_at' => meta_time(lead['created_time'] || created_time),
      'lead_branch' => branch,
      'consent_given' => consent[:given],
      'consent_checkbox_key' => consent[:checkbox_key],
      'consent_captured_at' => Time.current.iso8601
    }.compact
  end

  # Map a branch/city answer to our canonical branch key (Jubilee/Banjara/Film Nagar/Kokapet).
  def infer_branch(fields)
    raw = (fields[:branch] || fields[:city] || fields[:location] || fields[:preferred_branch]).to_s.downcase
    return 'jubilee_hills' if raw.include?('jubilee')
    return 'banjara_hills' if raw.include?('banjara')
    return 'film_nagar'    if raw.include?('film')
    return 'kokapet'       if raw.include?('kokapet')

    nil
  end

  def leadgen_inbox
    id = GlobalConfigService.load('NT_LEADGEN_INBOX_ID', nil)
    return Inbox.find(id) if id.present?

    Account.first.inboxes.find_by(name: 'Leads') || Account.first.inboxes.first
  end

  def normalize_phone(phone)
    return nil if phone.blank?

    digits = phone.to_s.gsub(/[^\d+]/, '')
    digits.start_with?('+') ? digits : "+#{digits}"
  end

  def meta_time(value)
    return nil if value.blank?

    (value.to_s =~ /\A\d+\z/ ? Time.zone.at(value.to_i) : Time.zone.parse(value.to_s)).iso8601
  rescue StandardError
    nil
  end

  # Immutable DPDPA audit note: what the lead submitted + the consent responses, at capture time.
  def write_consent_note(contact, lead, consent)
    body = +"🧾 Meta lead captured #{Time.current.iso8601}\n"
    body << "Consent given: #{consent[:given]} (#{consent[:checkbox_key]})\n"
    body << "Form: #{lead['form_id']}  Campaign: #{lead['campaign_name']}  Ad: #{lead['ad_id']}\n"
    body << "Platform: #{lead['platform']}  Created: #{lead['created_time']}\n"
    body << "Raw disclaimer responses: #{consent[:raw].to_json}"
    # Note#ensure_account_id derives account from the contact; content is the only required field.
    contact.notes.create!(content: body)
  rescue StandardError => e
    Rails.logger.warn("[meta-leadgen] consent note failed for contact #{contact.id}: #{e.message}")
  end
end
