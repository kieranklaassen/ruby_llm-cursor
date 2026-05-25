# frozen_string_literal: true

require "ruby_llm-cursor"
require "json"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

module FixtureHelper
  def load_events(name)
    path = File.join(__dir__, "fixtures", "#{name}.ndjson")
    File.readlines(path).map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
  end
end

RSpec.configure do |config|
  config.include FixtureHelper

  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  # :live specs hit the real cursor-agent CLI; opt in with CURSOR_LIVE=1.
  config.filter_run_excluding(:live) unless ENV["CURSOR_LIVE"]

  config.before do
    RubyLLM.configure do |c|
      c.cursor_api_key = nil
      c.cursor_agent_path = nil
      c.cursor_default_cwd = Dir.pwd
      c.cursor_mutation_mode = :ask
    end
  end
end
