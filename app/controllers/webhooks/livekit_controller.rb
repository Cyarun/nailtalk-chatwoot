# frozen_string_literal: true

# Webhooks::LivekitController — receives LiveKit server webhooks (POST) and, when an
# inbound SIP call from Vobiz lands (participant_joined, participant.kind == SIP),
# creates a native Chatwoot Call + voice_call Message via Voice::InboundCallBuilder so
# the incoming-call widget RINGS on the agent's browser (uatcrm) with live status.
#
# Flow: customer -> Vobiz -> LiveKit SIP -> room -> LiveKit posts participant_joined here
#       -> map sip.trunkPhoneNumber (dialed DID) to the voice inbox -> InboundCallBuilder.
#
# LiveKit signs each webhook with a JWT in the Authorization header whose payload carries
# a sha256 claim = base64(SHA256(raw body)). We verify both (signature + body hash).
# Route (config/routes.rb): post 'webhooks/livekit' -> 'webhooks/livekit#events'
class Webhooks::LivekitController < ActionController::API
  def events
    return head(:unauthorized) unless verify_livekit_signature!

    event = payload[%q{event}]
    Rails.logger.info(%Q{[livekit-webhook] event=#{event} kind=#{participant[%q{kind}].inspect} did=#{attributes[%q{sip.trunkPhoneNumber}].inspect} caller=#{attributes[%q{sip.phoneNumber}].inspect}})
    # Create the Chatwoot support Call ONLY when the caller pressed 9 (the IVR POSTs
    # a signed nailtalk_press_9 event). NOT on participant_joined - that rang the
    # agent for every inbound call before the caller chose a human.
    enqueue_inbound_call if event == 'nailtalk_press_9'
    head :ok
  end

  private

  def raw_body
    @raw_body ||= request.body.read
  end

  def payload
    @payload ||= JSON.parse(raw_body) rescue {}
  end

  def participant
    payload['participant'] || {}
  end

  def attributes
    participant['attributes'] || {}
  end

  # LiveKit ParticipantInfo.Kind: STANDARD=0, INGRESS=1, EGRESS=2, SIP=3, AGENT=4
  def sip_participant?
    k = participant[%q{kind}]
    k.to_s.upcase == %q{SIP} || k.to_i == 3
  end

  def enqueue_inbound_call
    dialed_did = normalize_e164(attributes['sip.trunkPhoneNumber'])
    caller     = normalize_e164(attributes['sip.phoneNumber'])
    call_id    = attributes['sip.callID'].presence || (payload.dig('room', 'name'))
    return if dialed_did.blank? || call_id.blank?

    channel = Channel::TwilioSms.find_by(phone_number: dialed_did)
    return unless channel&.voice_enabled?

    Voice::InboundCallBuilder.perform!(
      inbox: channel.inbox,
      from_number: caller,
      call_sid: call_id,
      provider: :livekit,
      extra_meta: { 'room_name' => payload.dig('room', 'name'), 'trunk_id' => attributes['sip.trunkID'] }
    )
  rescue StandardError => e
    Rails.logger.error("[livekit-webhook] inbound call ingest failed: #{e.class} #{e.message}")
  end

  # Normalize to E.164. Vobiz sends Indian callers like "08179245139" (leading 0,
  # no country code) — strip the 0 and prefix +91; a bare 10-digit gets +91 too;
  # an already-plus number is kept as-is.
  # Transition the call to a terminal status when it ends (no_answer if never
  # answered, completed if it was in progress) so the ringing card/button clears.
  def end_inbound_call
    call_id = attributes[%q{sip.callID}].presence || payload.dig(%q{room}, %q{name})
    room = payload.dig(%q{room}, %q{name})
    scope = Call.where(provider: :livekit)
    call = scope.find_by(provider_call_id: call_id)
    call ||= scope.where(%q{meta ->> ? = ?}, %q{room_name}, room).order(:created_at).last if room.present?
    return unless call && !Call::TERMINAL_STATUSES.include?(call.status)

    new_status = call.status == %q{in_progress} ? %q{completed} : %q{no_answer}
    Voice::CallStatus::Manager.new(call: call).process_status_update(new_status)
  rescue StandardError => e
    Rails.logger.error(%Q{[livekit-webhook] end call failed: #{e.class} #{e.message}})
  end

  def normalize_e164(num)
    return if num.blank?
    s = num.to_s.strip
    return s if s.start_with?(%q{+})

    digits = s.gsub(/\D/, %q{})
    digits = digits.delete_prefix(%q{0})
    digits = %Q{91#{digits}} if digits.length == 10
    %Q{+#{digits}}
  end

  # Verify the LiveKit-signed webhook: JWT in Authorization header signed with our
  # LIVEKIT_API_SECRET (iss == LIVEKIT_API_KEY), and its sha256 claim == base64(SHA256(body)).
  def verify_livekit_signature!
    token = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
    return false if token.blank?

    secret = ENV.fetch('LIVEKIT_API_SECRET', nil)
    key    = ENV.fetch('LIVEKIT_API_KEY', nil)
    return false if secret.blank?

    decoded, = JWT.decode(token, secret, true, algorithm: 'HS256')
    return false if key.present? && decoded['iss'] != key

    expected = Base64.strict_encode64(Digest::SHA256.digest(raw_body))
    ActiveSupport::SecurityUtils.secure_compare(decoded['sha256'].to_s, expected)
  rescue JWT::DecodeError, StandardError => e
    Rails.logger.warn("[livekit-webhook] signature verify failed: #{e.message}")
    false
  end
end
