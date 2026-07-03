class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end

  def initialize(account_id: nil)
    Llm::Config.initialize!
    @account_id = account_id
    @embedding_model = InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  # NailTalk (CRM 360): route embeddings through the OpenAI-compatible endpoint configured in
  # Llm::Config (our Gemini key + Gemini's OpenAI-compat base URL), forcing provider :openai so
  # RubyLLM does NOT take the native-Gemini path (which needs a separate gemini_api_key). We
  # request dimensions: 1536 so Gemini's gemini-embedding-001 (native 3072) is truncated to fit
  # Captain's vector(1536) column with no schema change. One key, one auth path, our own models.
  EMBED_DIMENSIONS = 1536

  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    instrument_embedding_call(instrumentation_params(content, model)) do
      api_key = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
      endpoint = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence
      api_base = endpoint ? "#{endpoint.chomp('/')}/v1" : nil
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base if api_base
      end
      RubyLLM.embed(content, model: model, provider: :openai, context: context,
                             assume_model_exists: true, dimensions: EMBED_DIMENSIONS).vectors
    end
  rescue RubyLLM::Error => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def instrumentation_params(content, model)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      input: content,
      feature_name: 'embedding',
      account_id: @account_id
    }
  end
end
