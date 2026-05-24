# frozen_string_literal: true

RSpec.describe RubyLLM::Cursor::Provider do
  def user(text)
    RubyLLM::Message.new(role: :user, content: text)
  end

  def provider_with(events)
    described_class.new(RubyLLM.config).tap { |p| p.cli = FakeCLI.new(events) }
  end

  describe "registration and resolution" do
    it "is registered under :cursor" do
      expect(RubyLLM::Provider.providers[:cursor]).to eq(described_class)
    end

    it "builds a usable Chat without opening a connection" do
      chat = RubyLLM.chat(model: "composer-2.5", provider: :cursor)
      provider = chat.instance_variable_get(:@provider)
      expect(provider).to be_a(described_class)
      expect(provider.connection).to be_nil
    end

    it "resolves arbitrary model ids (assume_models_exist?)" do
      expect { RubyLLM.chat(model: "totally-made-up-model", provider: :cursor) }.not_to raise_error
    end

    it "exposes configuration options through RubyLLM.configure" do
      RubyLLM.configure do |c|
        c.cursor_api_key = "sk-test"
        c.cursor_default_cwd = "/tmp"
      end
      expect(RubyLLM.config.cursor_api_key).to eq("sk-test")
      expect(RubyLLM.config.cursor_default_cwd).to eq("/tmp")
    end
  end

  describe "#complete (non-streaming)" do
    subject(:provider) { provider_with(load_events("simple_qa")) }

    it "returns an assistant Message whose content is the result text" do
      message = provider.complete([user("What is 2+2?")], model: "composer-2.5")
      expect(message).to be_a(RubyLLM::Message)
      expect(message.role).to eq(:assistant)
      expect(message.content).to eq("4")
    end

    it "never populates tool_calls" do
      message = provider.complete([user("What is 2+2?")], model: "composer-2.5")
      expect(message.tool_call?).to be(false)
    end

    it "captures token usage from the result event" do
      message = provider.complete([user("hi")], model: "composer-2.5")
      expect(message.input_tokens).to eq(33_052)
      expect(message.output_tokens).to eq(34)
      expect(message.cached_tokens).to eq(4823)
    end

    it "routes thinking into Message#thinking, not content" do
      message = provider.complete([user("hi")], model: "composer-2.5")
      expect(message.thinking&.text).to include("2 plus")
      expect(message.content).not_to include("2 plus")
    end

    it "defaults to read-only ask mode" do
      provider.complete([user("hi")], model: "composer-2.5")
      expect(provider.instance_variable_get(:@cli).calls.first[:mode]).to eq(:ask)
    end
  end

  describe "#complete (streaming)" do
    subject(:provider) { provider_with(load_events("streaming_deltas")) }

    it "streams incremental text without duplicating the consolidated block" do
      chunks = []
      message = provider.complete([user("colors")], model: "composer-2.5") { |chunk| chunks << chunk }
      streamed = chunks.map { |chunk| chunk.content.to_s }.join
      # The fixture ends with a consolidated full-text assistant event; it must
      # NOT be re-streamed (that previously doubled the output).
      expect(streamed).to eq("Red, Yellow, Blue")
      expect(message.content).to eq("Red, Yellow, Blue")
    end

    it "requests partial output when a block is given" do
      provider.complete([user("colors")], model: "composer-2.5") { |_| }
      expect(provider.instance_variable_get(:@cli).calls.first[:stream]).to be(true)
    end
  end

  describe "agentic events" do
    let(:events) do
      [
        { "type" => "system", "session_id" => "s1" },
        { "type" => "tool_call", "call_id" => "c1", "name" => "shell",
          "status" => "running", "args" => { "command" => "ls" } },
        { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "done" }] } },
        { "type" => "result", "result" => "done", "usage" => {} }
      ]
    end

    it "delivers every raw event, in order, to an on_event callback" do
      seen = []
      provider_with(events).complete(
        [user("do it")], model: "x", params: { cursor: { on_event: ->(e) { seen << e["type"] } } }
      )
      expect(seen).to eq(%w[system tool_call assistant result])
    end

    it "keeps tool events off Message#tool_calls" do
      message = provider_with(events).complete([user("do it")], model: "x")
      expect(message.tool_call?).to be(false)
      expect(message.content).to eq("done")
    end
  end

  describe "mutation posture" do
    subject(:provider) { provider_with(load_events("simple_qa")) }

    it "agent mode drops --mode and forces approval" do
      provider.complete([user("x")], model: "x", params: { cursor: { mutation_mode: :agent } })
      call = provider.instance_variable_get(:@cli).calls.first
      expect(call[:mode]).to be_nil
      expect(call[:force]).to be(true)
    end

    it "plan mode passes --mode plan and does not force" do
      provider.complete([user("x")], model: "x", params: { cursor: { mutation_mode: :plan } })
      call = provider.instance_variable_get(:@cli).calls.first
      expect(call[:mode]).to eq(:plan)
      expect(call[:force]).to be(false)
    end
  end

  describe "content fallback when result is blank" do
    let(:events) do
      [
        { "type" => "system", "session_id" => "s1" },
        { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "42" }] } },
        { "type" => "result", "result" => "", "usage" => { "inputTokens" => 1, "outputTokens" => 1 } }
      ]
    end

    it "uses the assistant message when cursor-agent returns an empty result" do
      message = provider_with(events).complete([user("which number?")], model: "x")
      expect(message.content).to eq("42")
    end
  end

  describe "error when no new turn" do
    it "raises rather than silently sending nothing" do
      provider = provider_with(load_events("simple_qa"))
      expect { provider.complete([], model: "x") }
        .to raise_error(RubyLLM::Error, /no new user message/)
    end
  end
end
