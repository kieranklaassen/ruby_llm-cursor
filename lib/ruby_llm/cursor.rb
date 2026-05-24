# frozen_string_literal: true

require "ruby_llm"

require_relative "cursor/version"
require_relative "cursor/errors"
require_relative "cursor/event_mapper"
require_relative "cursor/cli"
require_relative "cursor/provider"

module RubyLLM
  # Drives the local `cursor-agent` CLI as a RubyLLM chat provider.
  module Cursor
  end
end

# Register the provider so `RubyLLM.chat(provider: :cursor)` works with no fork
# of ruby_llm and no models.json edits. This also registers the provider's
# configuration options (config.cursor_api_key, etc.) via Configuration.
RubyLLM::Provider.register(:cursor, RubyLLM::Cursor::Provider)
