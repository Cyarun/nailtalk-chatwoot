# NeverMissLeadJob (nt-0exh) — the durable SAFETY NET that guarantees no WhatsApp lead is
# ever missed. Runs every few minutes (config/schedule.yml). Finds WhatsApp conversations
# where the customer's last message is UNANSWERED for > threshold, and re-engages:
#   - in-window (customer messaged < 24h ago) -> re-trigger Aria (ResponseBuilderJob), which
#     answers; if the window is closed the framework's SendOnWhatsappService auto-sends a
#     template instead (it checks conversation.can_reply?).
#   - already re-attempted once and STILL unanswered -> send the approved 'late_reply'
#     template directly, so an out-of-window lead is still reached.
# Every action is logged [never-miss-lead] with the conversation id so confidence is visible.
#
# This applies the "never miss a task" durability principle (nt-wj48) to REVENUE: a lead that
# slips is caught within one tick, not lost. Idempotent — a conversation already re-attempted
# in this window is skipped (tracked via additional_attributes) so we never spam a customer.
class NeverMissLeadJob < ApplicationJob
  queue_as :scheduled_jobs

  # Only these WhatsApp inboxes (prod inbox 6). Configurable via ENV for UAT.
  WHATSAPP_INBOX_IDS = (ENV.fetch('NEVER_MISS_INBOX_IDS', '6').split(',').map(&:to_i)).freeze
  UNANSWERED_MINUTES = ENV.fetch('NEVER_MISS_MINUTES', '10').to_i
  LOOKBACK_HOURS = ENV.fetch('NEVER_MISS_LOOKBACK_HOURS', '72').to_i
  FALLBACK_TEMPLATE = ENV.fetch('NEVER_MISS_TEMPLATE', 'late_reply')

  def perform
    Rails.logger.info("[never-miss-lead] tick inboxes=#{WHATSAPP_INBOX_IDS} threshold=#{UNANSWERED_MINUTES}m")
    scanned = 0
    reengaged = 0

    Conversation
      .where(inbox_id: WHATSAPP_INBOX_IDS)
      .where('last_activity_at > ?', LOOKBACK_HOURS.hours.ago)
      .where.not(status: Conversation.statuses[:resolved])
      .find_each do |conversation|
      scanned += 1
      next unless unanswered?(conversation)

      reengaged += 1 if reengage(conversation)
    end

    Rails.logger.info("[never-miss-lead] done scanned=#{scanned} reengaged=#{reengaged}")
  end

  private

  # A customer is waiting if their last incoming is newer than our last outgoing (or there is
  # no outgoing at all), and it's been longer than the threshold.
  def unanswered?(conversation)
    last_in = conversation.messages.where(message_type: :incoming).maximum(:created_at)
    return false if last_in.nil?
    return false if last_in > UNANSWERED_MINUTES.minutes.ago # too fresh — give Aria time

    last_out = conversation.messages.where(message_type: %i[outgoing template]).maximum(:created_at)
    last_out.nil? || last_out < last_in
  end

  def reengage(conversation)
    assistant = conversation.inbox.captain_assistant
    attempts = conversation.additional_attributes['never_miss_attempts'].to_i

    if assistant.present? && attempts.zero?
      # First catch: re-trigger the AI. In-window it answers; out-window the send service
      # falls back to a template automatically (SendOnWhatsappService#perform_reply).
      Rails.logger.info("[never-miss-lead] conv=#{conversation.display_id} -> re-trigger Aria (attempt 1)")
      Captain::Conversation::ResponseBuilderJob.perform_later(conversation, assistant)
      mark_attempt(conversation, attempts + 1)
      true
    elsif attempts < 2
      # Still unanswered after an AI attempt -> send the approved re-engagement template
      # directly (reaches even out-of-window leads within WhatsApp policy).
      Rails.logger.info("[never-miss-lead] conv=#{conversation.display_id} -> send template #{FALLBACK_TEMPLATE} (attempt #{attempts + 1})")
      send_reengage_template(conversation)
      mark_attempt(conversation, attempts + 1)
      true
    else
      # Already re-attempted twice — don't spam. Leave for human/ops review.
      Rails.logger.warn("[never-miss-lead] conv=#{conversation.display_id} still unanswered after #{attempts} attempts — needs review")
      false
    end
  rescue StandardError => e
    Rails.logger.error("[never-miss-lead] conv=#{conversation.display_id} error: #{e.message}")
    false
  end

  def send_reengage_template(conversation)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content_type: 'text',
      content: 'Sorry for the delay in responding. Let me know if you’re available to discuss your query now.',
      additional_attributes: { template_name: FALLBACK_TEMPLATE },
      sender: nil
    )
  end

  def mark_attempt(conversation, count)
    attrs = conversation.additional_attributes.merge('never_miss_attempts' => count, 'never_miss_last_at' => Time.current.iso8601)
    conversation.update!(additional_attributes: attrs)
  end
end
