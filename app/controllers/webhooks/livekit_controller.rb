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
    set_recording_url if event == 'nailtalk_call_ended'
    broadcast_call_transcript if event == 'nailtalk_transcript'
    persist_missed_call if event == 'nailtalk_call_missed'
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

  # Live call-screening transcript: the IVR screener POSTs each interim/final transcript
  # chunk as the caller states their reason. Broadcast it over ActionCable to the ringing
  # agent(s) so they see WHY the caller is calling — live, before they answer.
  def broadcast_call_transcript
    room = payload.dig('room', 'name')
    call_id = attributes['sip.callID'].presence || room
    return if call_id.blank?

    scope = Call.where(provider: :livekit)
    call = scope.find_by(provider_call_id: call_id)
    call ||= scope.where("meta ->> ? = ?", 'room_name', room).order(:created_at).last if room.present?
    return unless call

    tokens = [call.conversation&.assignee&.pubsub_token].compact
    tokens = call.account.users.pluck(:pubsub_token).compact if tokens.empty?
    return if tokens.empty?

    ActionCableBroadcastJob.perform_later(
      tokens, 'voice_call.transcript',
      { call_id: call.id, room_name: room,
        text: payload['text'].to_s, is_final: !!payload['is_final'] }
    )
  rescue StandardError => e
    Rails.logger.error("[livekit-webhook] transcript broadcast failed: #{e.class} #{e.message}")
  end

  # Missed internal call: the screener timed out without the receiver answering. Save the
  # caller's transcript on the Call (recording_url is set separately via egress) and notify
  # the receiver so they see the missed call AND what the caller said.
  def persist_missed_call
    room = payload.dig('room', 'name')
    call = Call.where(provider: :livekit).where("meta ->> ? = ?", 'room_name', room).order(:created_at).last
    return unless call

    call.update!(transcript: payload['text'].presence || payload['transcript'].to_s) if call.respond_to?(:transcript)
    call.update!(status: :no_answer) unless Call::TERMINAL_STATUSES.include?(call.status)

    # The CALLER must be told the call ended too — otherwise their outbound ringing/ringback
    # loops forever (the ring-never-stops bug on the timeout path). Reuse internal_call.ended
    # (the same event that cleanly tears down both sides for hangup/reject).
    if call.caller_user&.pubsub_token
      ActionCableBroadcastJob.perform_later(
        [call.caller_user.pubsub_token], 'internal_call.ended',
        { account_id: call.account_id, callSid: room, callId: call.id }
      )
    end

    # The CALLEE gets the missed-call alert with the caller's reason + recording.
    return unless call.callee_user&.pubsub_token

    ActionCableBroadcastJob.perform_later(
      [call.callee_user.pubsub_token], 'internal_call.missed',
      { account_id: call.account_id, callId: call.id, roomName: room,
        transcript: call.transcript.to_s,
        caller: { name: call.caller_user&.name },
        recording_url: call.recording_url }
    )
  rescue StandardError => e
    Rails.logger.error("[livekit-webhook] missed-call persist failed: #{e.class} #{e.message}")
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

  # Set the recording URL on the Call (from the IVR's nailtalk_call_ended signal) so the
  # audio player appears in the conversation. Then touch the message to re-broadcast.
  def set_recording_url
    url = payload['recording_url']
    call_id = attributes['sip.callID'].presence || payload.dig('room', 'name')
    return if url.blank? || call_id.blank?

    call = Call.where(provider: :livekit).find_by(provider_call_id: call_id)
    call ||= Call.where(provider: :livekit).where("meta ->> ? = ?", 'room_name', payload.dig('room', 'name')).order(:created_at).last
    return unless call

    call.update!(recording_url: url)
    call.message&.touch
  rescue StandardError => e
    Rails.logger.error("[livekit-webhook] set recording_url failed: #{e.class} #{e.message}")
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
