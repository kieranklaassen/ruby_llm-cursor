# frozen_string_literal: true

module RubyLLM
  module Cursor
    # A RubyLLM provider that bridges Cursor's stateful coding agent onto
    # RubyLLM's stateless Chat. One Chat maps to one provider instance (RubyLLM
    # builds a fresh instance per Chat), so the agent session id and the set of
    # already-forwarded turns live here safely.
    class Provider < RubyLLM::Provider
      DEFAULT_MUTATION_MODE = :ask

      def initialize(config) # rubocop:disable Lint/MissingSuper
        # Intentionally does NOT call super: the base builds a Faraday Connection
        # we never use. Cursor talks to a local subprocess instead.
        @config = config
        @session_id = nil
        @forwarded_message_ids = []
        @cli = CLI.new(config)
      end

      # Chat#with_model assigns `@connection = provider.connection`; nil is fine
      # because we never make HTTP requests.
      def connection
        nil
      end

      # Never used (we override #complete and never build a Connection), but
      # defined so any base-class path that reaches it does not raise.
      def api_base
        "cursor-agent://local"
      end

      # Injection seam for tests.
      attr_writer :cli

      def complete(messages, tools: {}, temperature: nil, model: nil, params: {}, headers: {},
                   schema: nil, thinking: nil, tool_prefs: nil, &block)
        cursor = cursor_params(params)
        on_event = cursor[:on_event]
        prompt = next_prompt(messages)
        raise RubyLLM::Error.new(nil, "cursor provider: no new user message to send") if prompt.nil?

        streaming = block_given?
        model_id = model.respond_to?(:id) ? model.id : model
        mode = mutation_mode(cursor)

        events = []
        text = +""
        thoughts = +""
        result_text = nil
        usage = nil

        @cli.run(
          prompt: prompt,
          model: model_id,
          workspace: workspace(cursor),
          mode: cli_mode(mode),
          resume: @session_id,
          api_key: @config.cursor_api_key,
          stream: streaming,
          force: force?(mode, cursor)
        ) do |event|
          events << event
          on_event&.call(event) # R9: every raw event, in order, to subscribers
          @session_id ||= EventMapper.session_id(event)

          if (fragment = EventMapper.assistant_text(event))
            text << fragment
            block.call(text_chunk(fragment, model_id)) if streaming
          elsif (thought = EventMapper.thinking_text(event))
            thoughts << thought
            block.call(thinking_chunk(thought, model_id)) if streaming
          elsif EventMapper.result?(event)
            result_text = EventMapper.result_text(event)
            usage = EventMapper.usage(event)
          end
        end

        mark_forwarded(messages)
        build_message(result_text || text, thoughts, usage, model_id, events)
      end

      class << self
        def slug
          "cursor"
        end

        def name
          "Cursor"
        end

        def configuration_options
          %i[cursor_api_key cursor_agent_path cursor_default_cwd cursor_default_model cursor_mutation_mode]
        end

        def configuration_requirements
          [] # cursor-agent may be authenticated out-of-band via `cursor-agent login`
        end

        def assume_models_exist?
          true
        end
      end

      private

      def cursor_params(params)
        value = (params || {})[:cursor]
        value.is_a?(Hash) ? value : {}
      end

      # The newest user message not yet forwarded to the agent. On the first turn
      # (no session yet), system instructions are prepended once.
      def next_prompt(messages)
        pending = messages.select { |m| m.role == :user && !@forwarded_message_ids.include?(m.object_id) }
        latest = pending.last
        return nil if latest.nil?

        text = message_text(latest)
        return text unless @session_id.nil?

        instructions = messages.select { |m| m.role == :system }.map { |m| message_text(m) }.reject(&:empty?)
        instructions.empty? ? text : (instructions + [text]).join("\n\n")
      end

      def mark_forwarded(messages)
        messages.each { |m| @forwarded_message_ids << m.object_id if m.role == :user }
      end

      def message_text(message)
        content = message.content
        return content if content.is_a?(String)
        return content.text.to_s if content.respond_to?(:text)

        content.to_s
      end

      def workspace(cursor)
        cursor[:workspace] || @config.cursor_default_cwd || Dir.pwd
      end

      def mutation_mode(cursor)
        (cursor[:mutation_mode] || @config.cursor_mutation_mode || DEFAULT_MUTATION_MODE).to_sym
      end

      # :ask and :plan are read-only CLI modes. :agent runs the full agent (no
      # --mode), which can edit files; that requires explicit opt-in.
      def cli_mode(mode)
        %i[ask plan].include?(mode) ? mode : nil
      end

      def force?(mode, cursor)
        return true if mode == :agent # headless agent runs cannot prompt for approval

        cursor[:force] ? true : false
      end

      def text_chunk(text, model_id)
        RubyLLM::Chunk.new(role: :assistant, model_id: model_id, content: text)
      end

      def thinking_chunk(text, model_id)
        RubyLLM::Chunk.new(
          role: :assistant,
          model_id: model_id,
          content: "",
          thinking: RubyLLM::Thinking.build(text: text)
        )
      end

      def build_message(content, thoughts, usage, model_id, events)
        usage ||= {}
        RubyLLM::Message.new(
          role: :assistant,
          content: content.to_s.empty? ? nil : content,
          model_id: model_id,
          thinking: RubyLLM::Thinking.build(text: thoughts),
          input_tokens: usage[:input],
          output_tokens: usage[:output],
          cached_tokens: usage[:cached],
          cache_creation_tokens: usage[:cache_creation],
          raw: events
        )
      end
    end
  end
end
