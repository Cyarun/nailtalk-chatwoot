# NailTalk native voice integration — makes Dograh calls NATIVELY FUNCTIONAL in Chatwoot,
# not "logged". Instead of posting a text note that looks like a call, this creates a REAL
# Chatwoot Call record via the platform's own Voice::InboundCallBuilder, so Chatwoot's native
# calling engine renders the native call bubble (with player + transcript), drives status
# (ringing -> completed) via Voice::CallStatus::Manager, and rings the FloatingCallWidget —
# all the native affordances, because it IS a native Call, not an imitation.
#
# Deploy: mount at /app/config/initializers/nt_native_voice.rb in the chatwoot-crm360 overlay.
# Two pieces:
#   1. Channel::Api#phone_number — the native Call serializer calls inbox.channel.phone_number
#      (via push_event_data); Channel::Api lacks it and raises NoMethodError, 500-ing the
#      conversation view. We read it from additional_attributes so a phone-bearing Channel::Api
#      inbox (the "Phone Calls" voice inbox) works with real Call records.
#   2. Nt::NativeVoice.log_call! — the entry point Dograh's telephony webhook calls to create/
#      update the native Call. Create on ring, transition on status, attach recording+transcript
#      on completion. Uses Voice::InboundCallBuilder + Voice::CallStatus::Manager — no text notes.
Rails.application.config.to_prepare do
  # 1) Give Channel::Api a phone_number so native Call serialization doesn't crash.
  #    The native Call serializer calls inbox.channel.phone_number; Channel::Api lacks it.
  #    We read it from additional_attributes if set, else fall back to NT_VOICE_PHONE_NUMBER
  #    (the salon DID) — the inbox update API doesn't permit additional_attributes, so the
  #    ENV fallback is the configurable native path (set on the chatwoot-rails/sidekiq env).
  Channel::Api.class_eval do
    def phone_number
      additional_attributes&.dig('phone_number') || ENV.fetch('NT_VOICE_PHONE_NUMBER', nil)
    end
  end

  module Nt
    module NativeVoice
      module_function

      VOICE_INBOX_ID = ENV.fetch('NT_VOICE_INBOX_ID', nil)

      # Create (on ring) or advance (on status) a NATIVE Call for a Dograh call.
      #   from_number:  caller MSISDN (E.164)
      #   call_id:      Dograh's stable call id (provider_call_id)
      #   status:       'ringing' | 'in_progress' | 'completed' | 'no_answer' | 'failed'
      #   recording_url / transcript: attached on completion
      #   duration_seconds, disposition: native meta
      def log_call!(from_number:, call_id:, status: 'ringing', recording_url: nil,
                    transcript: nil, duration_seconds: nil, disposition: nil, handled_by: nil)
        inbox = voice_inbox
        return unless inbox

        call = Call.find_by(inbox_id: inbox.id, provider: :twilio, provider_call_id: call_id)
        if call.nil?
          # provider :twilio is the enum stand-in (Dograh isn't an enum value); it only gates a
          # Twilio conference detail we don't use. The real identity is provider_call_id.
          call = Voice::InboundCallBuilder.perform!(
            inbox: inbox, from_number: from_number, call_sid: call_id, provider: :twilio,
            extra_meta: { 'source' => 'dograh', 'handled_by' => handled_by }.compact
          )
        end

        # advance status through the NATIVE state machine (guards terminal states +
        # re-broadcasts the bubble live). Manager uses pattr_initialize [:call!] — it wants
        # a keyword arg (call: call), NOT positional. process_status_update applies the update.
        if status.present?
          Voice::CallStatus::Manager.new(call: call).process_status_update(status, duration: duration_seconds)
        end

        # duration_seconds + transcript are real Call columns; write them directly (native).
        updates = {}
        updates[:duration_seconds] = duration_seconds if duration_seconds && call.duration_seconds.to_i.zero?
        updates[:transcript] = transcript if transcript.present? && call.transcript.blank?
        call.update!(updates) if updates.any?
        call.update!(meta: call.meta.merge('disposition' => disposition)) if disposition.present?

        attach_recording!(call, recording_url) if recording_url.present?
        call.message&.touch # force a live re-broadcast so the native bubble refreshes
        call
      end

      def voice_inbox
        return Inbox.find_by(id: VOICE_INBOX_ID) if VOICE_INBOX_ID
        Account.first.inboxes.find_by(name: 'Phone Calls')
      end

      # Native audio chip: attach the recording as an ActiveStorage blob on the call's message
      # so the native player works. (Streaming an external URL crashes audio_metadata; the
      # native player needs a real blob — so we fetch + attach.)
      def attach_recording!(call, url)
        return if call.recording.attached?
        io = URI.parse(url).open
        call.recording.attach(io: io, filename: "call-#{call.id}.mp3", content_type: 'audio/mpeg')
      rescue StandardError => e
        Rails.logger.warn("[nt-native-voice] recording attach failed: #{e.message}")
      end
    end
  end
end
