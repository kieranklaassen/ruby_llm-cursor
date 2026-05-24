# frozen_string_literal: true

# Stand-in for RubyLLM::Cursor::CLI. Replays recorded events to the block and
# records the keyword args of every #run call so specs can assert the argv-level
# contract (resume id, mode, stream, prompt) without spawning a process.
#
# `scripts` is either an array of event Hashes (replayed on every call) or an
# array of arrays (one event list per successive call).
class FakeCLI
  attr_reader :calls

  def initialize(scripts)
    @scripts = scripts
    @calls = []
  end

  def run(**kwargs, &on_event)
    @calls << kwargs
    events_for(@calls.size - 1).each { |event| on_event&.call(event) }
    :ok
  end

  private

  def events_for(index)
    if @scripts.is_a?(Array) && @scripts.first.is_a?(Array)
      @scripts[index] || []
    else
      @scripts
    end
  end
end
