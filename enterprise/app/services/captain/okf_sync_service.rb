# NailTalk OKF -> Captain knowledge sync (native).
#
# Keeps a Captain assistant's Q&A (Captain::AssistantResponse) in lock-step with the canonical
# OKF/Wix service catalog, so Captain never drifts from live prices/services. This is the NATIVE
# Ruby form of the retired host-side captain_sync_api.py: it runs INSIDE Chatwoot as a service
# object driven by a Sidekiq-cron job (Captain::OkfSyncJob) — no external script, no self-HTTP,
# no rails runner. It upserts Captain::AssistantResponse directly via ActiveRecord; the model's
# own `after_commit :update_response_embedding` regenerates the pgvector embedding natively.
#
# Idempotent: diffs the desired Q&A set against the live set and only creates new / updates
# changed / deletes stale price Q&A. A run that is already in sync mutates nothing.
#
# Catalog source (in order of precedence):
#   - OKF_CATALOG_URL   — HTTP(S) endpoint returning the OKF service_ids.json (preferred; clean
#                         separation, OKF owns the data)
#   - OKF_CATALOG_PATH  — a file path reachable inside the container (a bind-mounted catalog)
#                         default: /okf/service_ids.json
#   - CAPTAIN_OKF_ASSISTANT_ID — which assistant to sync (default 1 = Aria)
#
# The desired Q&A content is byte-for-byte the same the Python produced: one price fact per
# priced service (with locations + the Rs 100 deposit line) plus a fixed FAQ set.
class Captain::OkfSyncService
  DEFAULT_CATALOG_PATH = ENV.fetch('OKF_CATALOG_PATH', '/okf/service_ids.json')

  # Fixed FAQs kept in lock-step too — identical content to the retired captain_sync_api.py.
  FIXED_FAQS = {
    'What are your branches / locations?' =>
      'Nail Talk has four branches in Hyderabad: Jubilee Hills, Banjara Hills, ' \
      'Film Nagar, and Kokapet.',
    'What are your timings / hours?' =>
      'We are open every day from 11:15 AM to 8:30 PM.',
    'How do I book / booking?' =>
      'You can book online. A Rs 100 deposit confirms your booking. I can share the ' \
      'booking link for your preferred branch.',
    'Do you take walk-ins?' =>
      'We recommend booking in advance to secure your slot, but you can call your ' \
      'nearest branch to check availability.',
    'What is the deposit?' =>
      'A Rs 100 deposit confirms your booking and is adjusted against your service.'
  }.freeze

  def initialize(assistant: nil, dry_run: false)
    @assistant = assistant || default_assistant
    @dry_run = dry_run
  end

  # Diff desired vs live; create new / update changed / delete stale price Q&A.
  # Returns a summary hash (safe to log). dry_run computes the diff without mutating.
  def perform
    raise 'Captain::OkfSyncService: no assistant to sync' if @assistant.nil?

    desired = build_desired(load_catalog)
    live = fetch_live # { question => AssistantResponse }

    to_add    = desired.reject { |q, _a| live.key?(q) }
    to_update = desired.select { |q, a| live.key?(q) && live[q].answer != a }
    # only prune the price/FAQ Q&A this syncer owns — never touch responses we didn't author
    owned = desired.keys.to_set | live.keys.select { |q| price_question?(q) }.to_set
    to_prune = live.reject { |q, _r| desired.key?(q) }.select { |q, _r| owned.include?(q) }

    apply!(live, to_add, to_update, to_prune) unless @dry_run

    {
      added: to_add.size, updated: to_update.size, pruned: to_prune.size,
      desired_total: desired.size, live_total: live.size, dry_run: @dry_run,
      assistant_id: @assistant.id
    }
  end

  private

  def default_assistant
    id = ENV.fetch('CAPTAIN_OKF_ASSISTANT_ID', '1').to_i
    Captain::Assistant.find_by(id: id) || Captain::Assistant.first
  end

  # Build the canonical Q&A set from the catalog — one price fact per priced service + FAQs.
  def build_desired(catalog)
    desired = {}
    (catalog['services'] || {}).each_value do |v|
      next if v['price'].blank?

      name = v['name']
      locs = Array(v['locations']).filter_map { |l| l['name'] }.join(', ')
      question = "How much is #{name}? / #{name} price"
      answer = "#{name} costs Rs #{v['price'].to_f.to_i}."
      answer += " Available at #{locs}." if locs.present?
      answer += ' A Rs 100 deposit confirms the booking.'
      desired[question] = answer
    end
    desired.merge(FIXED_FAQS)
  end

  # A price Q&A this syncer authors looks like "How much is X? / X price".
  def price_question?(question)
    question.to_s.start_with?('How much is ')
  end

  def fetch_live
    @assistant.responses.each_with_object({}) do |resp, acc|
      acc[resp.question] = resp
    end
  end

  def apply!(live, to_add, to_update, to_prune)
    to_add.each do |question, answer|
      @assistant.responses.create!(
        question: question, answer: answer,
        account: @assistant.account, status: :approved
      )
    end
    # updating the answer triggers native re-embedding via after_commit :update_response_embedding
    to_update.each { |question, answer| live[question]&.update!(answer: answer) }
    to_prune.each_value(&:destroy!)
  end

  # Load the OKF catalog from an HTTP endpoint (preferred) or a mounted file path.
  def load_catalog
    url = ENV.fetch('OKF_CATALOG_URL', nil)
    raw = if url.present?
            require 'net/http'
            Net::HTTP.get(URI(url))
          else
            File.read(DEFAULT_CATALOG_PATH)
          end
    JSON.parse(raw)
  end
end
