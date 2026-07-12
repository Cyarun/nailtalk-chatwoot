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
    # Ensure lead_leadgen_id is always set (the webhook always gives us leadgen_id even if the
    # fetched lead payload omits 'id') — idempotency/dedupe depends on it.
    attrs['lead_leadgen_id'] = attrs['lead_leadgen_id'].presence || leadgen_id.to_s

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

    # CONTACT-FIRST journey: do NOT dump a conversation into the Leads inbox. The lead
    # is captured + enriched as a Contact (source of truth) and labelled for the native
    # warm-welcome + nurture Automations. Booking is INBOUND-ONLY (the lead reaches out).
    # The branch is stored on the contact so branch-routing/segmentation can use it.
    contact.update!(custom_attributes: contact.custom_attributes.merge(
      { 'lead_stage' => 'new' }.merge(attrs['lead_branch'] ? { 'lead_branch' => attrs['lead_branch'] } : {})
    ))
    apply_lead_labels(contact, attrs)

    write_consent_note(contact, lead, consent)

    # TIME IS MONEY ON INTENT: message the lead on WhatsApp the moment the form lands, so
    # they hear from us while still warm. Native template send via our WhatsApp Cloud inbox.
    send_whatsapp_welcome(contact, fields)

    Rails.logger.info("[meta-leadgen] ingested lead #{leadgen_id} -> contact #{contact.id} (contact-first + WhatsApp welcome)")
    contact
  end

  # Send the lead_welcome WhatsApp template the NATIVE Chatwoot way: create a Conversation
  # in our WhatsApp inbox + an outgoing template Message — Chatwoot's Whatsapp::SendOnWhatsappService
  # then delivers the template AND logs it in the conversation (so the agent/Aria sees it and
  # can handle the reply). Uses the same builders the FB/IG/WhatsApp channels use.
  # Gated by NT_LEAD_WA_TEMPLATE (template name) so it can be flipped on/off safely.
  def send_whatsapp_welcome(contact, fields)
    template_name = GlobalConfigService.load('NT_LEAD_WA_TEMPLATE', nil)
    return if template_name.blank?

    to = normalize_phone(fields[:phone_number])
    return if to.blank?

    inbox = whatsapp_inbox
    return if inbox.blank?

    # WhatsApp Cloud requires the ContactInbox source_id to be DIGITS ONLY (regex \A\d{1,15}\z) —
    # normalize_phone returns a +E.164 string, so strip the leading + here.
    source_id = to.delete('^0-9')

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: source_id,
      contact_attributes: { name: contact.name, phone_number: to }
    ).perform

    conversation = ::ConversationBuilder.new(
      params: ActionController::Parameters.new({}),
      contact_inbox: contact_inbox
    ).perform

    # Read the template's REAL language + category from the WABA (hardcoding en_US/MARKETING
    # was wrong — this template is 'en'/UTILITY, and a mismatch triggers Meta #132001). Also
    # fill the template's body variables ({{1}} name, {{2}} branch/salon) or Meta returns #132000.
    tmpl = (inbox.channel.message_templates || []).find { |t| t['name'] == template_name }
    language = tmpl&.dig('language') || 'en'
    category = tmpl&.dig('category') || 'UTILITY'
    branch = fields[:branch].presence || 'Salon'

    msg_params = ActionController::Parameters.new(
      message_type: 'outgoing',
      content: "Hi #{contact.name}, thank you for your interest in Nail Talk #{branch}!",
      template_params: {
        name: template_name, category: category, language: language,
        processed_params: { '1' => contact.name.to_s, '2' => branch.to_s }
      }
    )
    ::Messages::MessageBuilder.new(nil, conversation, msg_params).perform
    Rails.logger.info("[meta-leadgen] WhatsApp welcome (#{template_name}/#{language}) queued in conversation #{conversation.id} to #{to}")
  rescue StandardError => e
    Rails.logger.error("[meta-leadgen] WhatsApp welcome send failed: #{e.message}")
  end

  # Our WhatsApp Cloud inbox (NT_LEAD_WA_INBOX_ID, else the first WhatsApp inbox).
  def whatsapp_inbox
    inbox_id = config_inbox_id('NT_LEAD_WA_INBOX_ID')
    inbox_id ? Inbox.find_by(id: inbox_id) : Inbox.find_by(channel_type: 'Channel::Whatsapp')
  end

  # Read an inbox-id config value as a numeric id, or nil. Treats blanks AND non-numeric
  # sentinels (e.g. the literal "UNSET" placeholder) as "not configured" — a raw
  # GlobalConfigService.load(...).present? was TRUE for "UNSET", so Inbox.find("UNSET")
  # raised RecordNotFound and killed the whole ingest job before the WhatsApp welcome ran.
  def config_inbox_id(key)
    raw = GlobalConfigService.load(key, nil).to_s.strip
    raw.match?(/\A\d+\z/) ? raw : nil
  end

  # Native labels for segmentation / warm-welcome automations (meta-lead + branch-<x>).
  def apply_lead_labels(contact, attrs)
    labels = ['meta-lead', 'lead-new']
    labels << "branch-#{attrs['lead_branch']}" if attrs['lead_branch'].present?
    contact.update!(label_list: (contact.label_list | labels))
  rescue StandardError => e
    Rails.logger.warn("[meta-leadgen] label apply failed: #{e.message}")
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
      'service_interest' => infer_service_interest(fields, lead),
      'consent_given' => consent[:given],
      'consent_checkbox_key' => consent[:checkbox_key],
      'consent_captured_at' => Time.current.iso8601
    }.compact
  end

  # The service the lead is interested in — from an explicit form field if present, else
  # inferred from the ad/campaign name (86% of Nail Talk leads are eyelash ads). Lets the
  # agent open with the right service instead of a generic greeting.
  def infer_service_interest(fields, lead)
    explicit = fields[:service] || fields[:service_interest] || fields[:interested_in]
    return explicit.to_s if explicit.present?

    text = "#{lead['ad_name']} #{lead['campaign_name']}".downcase
    return 'eyelash_extensions' if text.match?(/lash|eyelash/)
    return 'nail_extensions'    if text.match?(/nail extension|gel|acrylic/)
    return 'manicure'           if text.include?('manicure')
    return 'pedicure'           if text.include?('pedicure')
    return 'makeup'             if text.match?(/makeup|bridal|bride/)

    nil
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
    id = config_inbox_id('NT_LEADGEN_INBOX_ID')
    return Inbox.find_by(id: id) || raise_missing_leadgen_inbox(id) if id

    Account.first.inboxes.find_by(name: 'Leads') || Account.first.inboxes.first
  end

  def raise_missing_leadgen_inbox(id)
    raise ActiveRecord::RecordNotFound, "NT_LEADGEN_INBOX_ID=#{id} does not match any Inbox"
  end

  # Normalize + VALIDATE the lead's phone. Returns a +E.164 Indian mobile, or nil for a
  # junk/fake number so we don't waste a paid WhatsApp template send on an unreachable lead.
  def normalize_phone(phone)
    return nil if phone.blank?

    digits = phone.to_s.gsub(/\D/, '')
    # Strip a leading country code / trunk 0 to get the bare 10-digit subscriber number.
    digits = digits[2..] if digits.length == 12 && digits.start_with?('91')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('0')

    # Valid Indian mobile = 10 digits starting 6-9. Anything else is a fake/landline/foreign.
    unless digits.length == 10 && digits.match?(/\A[6-9]\d{9}\z/)
      Rails.logger.info("[meta-leadgen] skipping unreachable/invalid phone #{phone.inspect} (not a valid Indian mobile)")
      return nil
    end
    "+91#{digits}"
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
