require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def with_api_key(api_key, api_base: nil)
      initialize!
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base
        config.openrouter_api_key = api_key
      end

      yield context
    end

    private

    def configure_ruby_llm
      RubyLLM.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = openai_endpoint.chomp('/') if openai_endpoint.present?
        # NailTalk (CRM 360): our key is an OpenRouter key and our endpoint IS OpenRouter's
        # OpenAI-compatible API. Provider-prefixed models (e.g. "google/gemini-2.5-flash-lite")
        # make RubyLLM auto-route to its native :openrouter provider, which needs its OWN key —
        # otherwise Copilot/Captain fail with "Missing configuration for OpenRouter". Set it so
        # both the openai-compat path AND the openrouter-routed path use our single key.
        if system_api_key.present?
          config.openrouter_api_key = system_api_key rescue nil
        end
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
      end
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end
  end
end
