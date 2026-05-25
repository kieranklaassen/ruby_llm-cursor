# frozen_string_literal: true

RSpec.describe RubyLLM::Cursor::EventMapper do
  it "extracts session_id from the system event only" do
    expect(described_class.session_id({ "type" => "system", "session_id" => "s" })).to eq("s")
    expect(described_class.session_id({ "type" => "assistant", "session_id" => "s" })).to be_nil
  end

  it "extracts assistant text from content blocks" do
    event = { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "hello" }] } }
    expect(described_class.assistant_text(event)).to eq("hello")
  end

  it "returns nil assistant text for non-assistant events" do
    expect(described_class.assistant_text({ "type" => "result", "result" => "x" })).to be_nil
  end

  it "distinguishes streamed deltas from consolidated assistant events" do
    delta = { "type" => "assistant", "timestamp_ms" => 5,
              "message" => { "content" => [{ "type" => "text", "text" => "Red" }] } }
    mid_consolidated = { "type" => "assistant", "timestamp_ms" => 6, "model_call_id" => "m1",
                         "message" => { "content" => [{ "type" => "text", "text" => "Red, Blue" }] } }
    final_consolidated = { "type" => "assistant",
                           "message" => { "content" => [{ "type" => "text", "text" => "Red, Blue" }] } }

    expect(described_class.assistant_delta?(delta)).to be(true)
    expect(described_class.assistant_complete?(delta)).to be(false)
    expect(described_class.assistant_delta?(mid_consolidated)).to be(false)
    expect(described_class.assistant_complete?(mid_consolidated)).to be(true)
    expect(described_class.assistant_delta?(final_consolidated)).to be(false)
    expect(described_class.assistant_complete?(final_consolidated)).to be(true)
  end

  it "extracts thinking deltas but not the completed marker" do
    expect(described_class.thinking_text({ "type" => "thinking", "subtype" => "delta", "text" => "t" })).to eq("t")
    expect(described_class.thinking_text({ "type" => "thinking", "subtype" => "completed" })).to be_nil
  end

  it "maps cursor usage onto RubyLLM token fields" do
    event = { "type" => "result",
              "usage" => { "inputTokens" => 10, "outputTokens" => 2, "cacheReadTokens" => 3, "cacheWriteTokens" => 1 } }
    expect(described_class.usage(event)).to eq(input: 10, output: 2, cached: 3, cache_creation: 1)
  end

  it "flags tool/edit/shell events as agentic but not lifecycle events" do
    expect(described_class.agentic?({ "type" => "tool_call" })).to be(true)
    expect(described_class.agentic?({ "type" => "assistant" })).to be(false)
    expect(described_class.agentic?({ "type" => "result" })).to be(false)
    expect(described_class.agentic?({ "type" => "system" })).to be(false)
  end

  it "reads the result text from a real captured fixture" do
    events = load_events("simple_qa")
    result = events.find { |event| described_class.result?(event) }
    expect(described_class.result_text(result)).to eq("4")
  end
end
