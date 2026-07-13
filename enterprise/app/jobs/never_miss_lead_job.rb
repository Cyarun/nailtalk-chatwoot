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

  # Phrases that PROMISE a follow-up but are NOT a real answer. A conversation whose last
  # outgoing is one of these is still effectively unanswered — the customer is waiting for
  # the promised reply that never came (Anusha's case, nt-7390).
  HOLDING_REPLY = /\b(let me (check|confirm|get back|find out)|bear with|hold on|one moment|checking (with|this)|get back to you|will (check|confirm|update))\b/i

  # A customer is waiting if:
  #   (a) their last incoming is newer than our last real outgoing (or no outgoing), OR
  #   (b) our last outgoing was a HOLDING reply ("let me confirm...") that has gone stale
  #       with no real follow-up — a promise is not an answer.
  # And it's been longer than the threshold (give Aria time on a fresh message).
  def unanswered?(conversation)
    last_in_msg = conversation.messages.where(message_type: :incoming).order(:created_at).last
    return false if last_in_msg.nil?
    last_in = last_in_msg.created_at

    # API-FAILURE WATCHER (nt-jf9c): a message whose SEND FAILED (Meta/WhatsApp/Flue/Wix error
    # -> status :failed) did NOT actually reach the customer, so it must NOT count as an answer.
    # Excluding failed outgoing means a conversation stalled by a transient API failure is seen
    # as still-unanswered and gets re-engaged (self-heals) instead of leaving the customer stuck.
    last_out_msg = conversation.messages
                               .where(message_type: %i[outgoing template])
                               .where.not(status: :failed)
                               .order(:created_at).last
    last_out = last_out_msg&.created_at

    # Fresh — give the normal flow time to answer.
    reference = [last_in, last_out].compact.max
    return false if reference > UNANSWERED_MINUTES.minutes.ago

    # (a) customer's message is newer than our last reply
    return true if last_out.nil? || last_out < last_in

    # (b) our last reply was a holding promise -> still unanswered
    last_out_msg&.content.to_s.match?(HOLDING_REPLY)
  end

  def reengage(conversation)
    assistant = conversation.inbox.captain_assistant

    # THE FIX (nt-7390): the never-miss job is the true CHANNEL-WATCHER — it must respond to
    # EVERY new customer message, on ANY status (open/pending), not just the first N times.
    # A customer who replies again (esp. after a human touched the convo -> status 'open',
    # where Chatwoot's own trigger requires 'pending' and so never fires Aria) must still get
    # a reply. So: track the LAST incoming we already handled; if the customer's latest
    # incoming is NEWER, this is a fresh unanswered message -> re-trigger Aria (reset the
    # per-message attempt counter). The attempt cap only guards a SINGLE unanswered message
    # from being retried forever, not the whole conversation.
    last_in = conversation.messages.where(message_type: :incoming).maximum(:created_at)
    handled_at = conversation.additional_attributes['never_miss_handled_at']
    handled_time = handled_at.present? ? Time.zone.parse(handled_at) : nil
    new_customer_message = handled_time.nil? || (last_in && last_in > handled_time)

    attempts = new_customer_message ? 0 : conversation.additional_attributes['never_miss_attempts'].to_i

    if assistant.present? && attempts.zero?
      # Fresh unanswered customer message -> re-trigger the AI.
      # CRITICAL (nt-97uh): Aria's Chatwoot trigger (should_process_captain_response?) requires
      # conversation.pending?. Once a customer is handed off / assigned to a human, the convo
      # becomes 'open' (not pending) -> Aria won't fire -> the customer is stranded in the
      # unstaffed-human VOID (all handoffs pile on 'Nail Talk Support' who never replies). Since
      # no human works this inbox, the safety net RECLAIMS the conversation: set it back to
      # pending + un-assign, so Aria actually responds. This is what converts the void back into
      # an answered customer.
      unless conversation.pending?
        Rails.logger.info("[never-miss-lead] conv=#{conversation.display_id} reclaiming from status=#{conversation.status} assignee=#{conversation.assignee_id} -> pending (unstaffed-void rescue)")
        conversation.update!(status: :pending, assignee_id: nil)
      end
      Rails.logger.info("[never-miss-lead] conv=#{conversation.display_id} -> re-trigger Aria (new/unanswered msg)")
      Captain::Conversation::ResponseBuilderJob.perform_later(conversation, assistant)
      mark_attempt(conversation, 1, last_in)
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

  # handled_at = the timestamp of the incoming message this attempt is responding to. Storing
  # it lets the next tick tell whether a NEWER customer message has since arrived (=> reset).
  def mark_attempt(conversation, count, handled_at = nil)
    attrs = conversation.additional_attributes.merge(
      'never_miss_attempts' => count,
      'never_miss_last_at' => Time.current.iso8601
    )
    attrs['never_miss_handled_at'] = handled_at.iso8601 if handled_at.present?
    conversation.update!(additional_attributes: attrs)
  end
end
