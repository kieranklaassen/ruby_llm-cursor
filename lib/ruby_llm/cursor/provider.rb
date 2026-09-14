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

      def complete(messages, model: nil, provider_options: {}, **_options, &block)
        cursor = cursor_params(provider_options)
        on_event = cursor[:on_event]
        prompt = next_prompt(messages)
        raise RubyLLM::Error, "cursor provider: no new user message to send" if prompt.nil?

        streaming = block_given?
        model_id = model.respond_to?(:id) ? model.id : model
        mode = mutation_mode(cursor)

        events = []
        delta_text = +""
        last_full = nil
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

          if EventMapper.assistant_delta?(event)
            fragment = EventMapper.assistant_text(event)
            delta_text << fragment
            block.call(text_chunk(fragment, model_id)) if streaming
          elsif EventMapper.assistant_complete?(event)
            # Consolidated repeat of an already-streamed block — never re-stream
            # it (that doubled the output); keep it only as a content fallback.
            last_full = EventMapper.assistant_text(event)
          elsif (thought = EventMapper.thinking_text(event))
            thoughts << thought
            block.call(thinking_chunk(thought, model_id)) if streaming
          elsif EventMapper.result?(event)
            result_text = EventMapper.result_text(event)
            usage = EventMapper.usage(event)
          end
        end

        mark_forwarded(messages)
        # Prefer the result text, but fall back to the last full assistant message
        # or the streamed deltas when result is blank (cursor-agent occasionally
        # emits an empty result even though assistant text was produced).
        content = first_present(result_text, last_full, delta_text)
        build_message(content, thoughts, usage, model_id, events)
      end

      # Cursor consumes message text itself, so it has no protocol-level
      # attachment preprocessing to perform.
      def preprocess_message(message, **_options)
        message
      end

      class << self
        def slug
          "cursor"
        end

        def display_name
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

        def local?
          true
        end
      end

      private

      def cursor_params(provider_options)
        value = (provider_options || {})[:cursor]
        value.is_a?(Hash) ? value : {}
      end

      # First candidate that is non-nil and not blank (treats "" as absent).
      def first_present(*candidates)
        candidates.find { |candidate| candidate && !candidate.to_s.strip.empty? }
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
        RubyLLM::Chunk.new(role: :assistant, model: model_id, content: text)
      end

      def thinking_chunk(text, model_id)
        RubyLLM::Chunk.new(
          role: :assistant,
          model: model_id,
          content: "",
          thinking: RubyLLM::Thinking.build(text: text)
        )
      end

      def build_message(content, thoughts, usage, model_id, events)
        usage ||= {}
        RubyLLM::Message.new(
          role: :assistant,
          content: content.to_s.empty? ? nil : content,
          model: model_id,
          thinking: RubyLLM::Thinking.build(text: thoughts),
          input_tokens: usage[:input],
          output_tokens: usage[:output],
          cache_read_tokens: usage[:cached],
          cache_write_tokens: usage[:cache_creation],
          raw: events
        )
      end
    end
  end
end
