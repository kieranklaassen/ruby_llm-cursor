# frozen_string_literal: true

module RubyLLM
  module Cursor
    # Maps cursor-agent failures (non-zero exit + stderr) onto RubyLLM error
    # types, and scrubs secrets out of any stderr we surface.
    module Errors
      module_function

      # Returns a RubyLLM error instance to raise (does not raise itself).
      def classify(status:, stderr:, api_key: nil)
        raw = stderr.to_s
        message = scrub(raw.strip, api_key)
        message = "cursor-agent exited with status #{status}" if message.empty?

        error_class_for(raw).new(message)
      end

      def error_class_for(stderr)
        case stderr
        when /not (?:logged in|authenticated)|unauthor|invalid api key|no api key/i
          RubyLLM::UnauthorizedError
        when /rate.?limit|quota|too many requests/i
          RubyLLM::RateLimitError
        when /cannot use this model|available models|unknown model|no such model/i
          RubyLLM::BadRequestError
        else
          RubyLLM::ServerError
        end
      end

      # Redact the API key value and drop any line that looks like it carries a
      # credential, before the text reaches an exception message or a log.
      def scrub(text, api_key)
        out = text.dup
        out = out.gsub(api_key, "[REDACTED]") if api_key && !api_key.to_s.empty?
        out
          .each_line
          .reject { |line| line.match?(/(?:api[_-]?key|token|secret|password)\s*[:=]/i) }
          .join
          .strip
      end
    end
  end
end
