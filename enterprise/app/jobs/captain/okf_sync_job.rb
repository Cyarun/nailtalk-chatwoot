# NailTalk: native Sidekiq-cron job that keeps Captain's knowledge in lock-step with the OKF/Wix
# catalog. Registered in config/schedule.yml at the same 30-min cadence as the OKF refresh, so one
# Wix pull -> voice KB + service_ids + Captain Q&A all stay in sync with zero drift. Replaces the
# host-side captain_sync_api.py cron step with a first-class in-app background job.
#
# No-op safety: if Captain isn't enabled / no assistant exists / catalog unreachable, it logs and
# returns without raising, so a missing catalog never crashes the scheduler.
class Captain::OkfSyncJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(assistant_id = nil)
    assistant = assistant_id ? Captain::Assistant.find_by(id: assistant_id) : nil
    summary = Captain::OkfSyncService.new(assistant: assistant).perform
    Rails.logger.info(
      "[captain-okf-sync] assistant=#{summary[:assistant_id]} " \
      "+#{summary[:added]} added, #{summary[:updated]} updated, #{summary[:pruned]} pruned " \
      "(desired=#{summary[:desired_total]} live=#{summary[:live_total]})"
    )
    summary
  rescue Errno::ENOENT, SocketError, JSON::ParserError => e
    # catalog file missing / OKF endpoint unreachable / bad JSON — log, don't crash the scheduler
    Rails.logger.warn("[captain-okf-sync] skipped: #{e.class}: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[captain-okf-sync] failed: #{e.class}: #{e.message}")
    raise
  end
end
