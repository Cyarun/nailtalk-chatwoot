# frozen_string_literal: true

# Backstop timeout for internal calls: if a call is STILL "ringing" after the ring window
# (nobody answered AND the screener never fired its timeout — e.g. dispatch failed), force
# it to no_answer and tell both parties, so the call doesn't stay "ringing" forever and
# permanently trip callee_busy? for the callee. Independent of the external screener agent.
class Voice::ExpireRingingCallJob < ApplicationJob
  queue_as :low

  def perform(call_id)
    call = Call.find_by(id: call_id)
    return unless call && call.status == 'ringing'

    call.update!(status: :no_answer)
    room = call.meta['room_name']

    tokens = [call.caller_user&.pubsub_token, call.callee_user&.pubsub_token].compact
    return if tokens.empty?

    ActionCableBroadcastJob.perform_later(
      tokens, 'internal_call.ended',
      { account_id: call.account_id, callSid: room, callId: call.id }
    )
    Rails.logger.info("[internal-call] backstop expired ringing call #{call_id} -> no_answer")
  rescue StandardError => e
    Rails.logger.warn("[internal-call] expire job failed for #{call_id}: #{e.class} #{e.message}")
  end
end
