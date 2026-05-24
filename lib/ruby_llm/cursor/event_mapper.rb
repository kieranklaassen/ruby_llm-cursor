# frozen_string_literal: true

module RubyLLM
  module Cursor
    # Translates raw cursor-agent NDJSON event hashes into the pieces the
    # provider needs. Pure functions over a parsed event Hash; no state.
    #
    # Observed event shapes (cursor-agent 2026.05, `--output-format stream-json`):
    #   {"type":"system","subtype":"init","session_id":"...","model":"...","permissionMode":"..."}
    #   {"type":"user","message":{...}}
    #   {"type":"thinking","subtype":"delta","text":"..."}
    #   {"type":"thinking","subtype":"completed"}
    #   {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"..."}]}}
    #   {"type":"result","subtype":"success","is_error":false,"result":"...","usage":{...}}
    # Tool/edit/shell/status/task events are passthrough-only and observational.
    module EventMapper
      module_function

      def type(event)
        event["type"]
      end

      def session_id(event)
        event["session_id"] if event["type"] == "system"
      end

      # Assistant text. A fragment when --stream-partial-output is set, otherwise
      # the full message text. nil for non-assistant events.
      def assistant_text(event)
        return nil unless event["type"] == "assistant"

        extract_text(event.dig("message", "content"))
      end

      def thinking_text(event)
        return nil unless event["type"] == "thinking" && event["subtype"] == "delta"

        event["text"]
      end

      def result?(event)
        event["type"] == "result"
      end

      def result_text(event)
        event["result"]
      end

      def error_result?(event)
        result?(event) && event["is_error"] == true
      end

      # Maps cursor-agent's camelCase usage onto RubyLLM's token fields.
      def usage(event)
        usage = event["usage"]
        return nil unless usage.is_a?(Hash)

        {
          input: usage["inputTokens"],
          output: usage["outputTokens"],
          cached: usage["cacheReadTokens"],
          cache_creation: usage["cacheWriteTokens"]
        }
      end

      # True for tool calls, file edits, shell commands, status, task milestones —
      # everything that is neither lifecycle nor assistant text/thinking/result.
      # These are surfaced observationally and never become Message#tool_calls.
      def agentic?(event)
        !%w[system user thinking assistant result].include?(event["type"])
      end

      def extract_text(content)
        return content if content.is_a?(String)
        return nil unless content.is_a?(Array)

        content.filter_map { |block| block["text"] if block["type"] == "text" }.join
      end
    end
  end
end
