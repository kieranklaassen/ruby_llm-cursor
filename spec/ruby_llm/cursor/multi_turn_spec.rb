# frozen_string_literal: true

RSpec.describe "Cursor multi-turn state machine" do
  def user(text)
    RubyLLM::Message.new(role: :user, content: text)
  end

  def turn(session_id, result)
    [
      { "type" => "system", "session_id" => session_id },
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => result }] } },
      { "type" => "result", "result" => result, "usage" => {} }
    ]
  end

  let(:provider) do
    RubyLLM::Cursor::Provider.new(RubyLLM.config).tap do |p|
      p.cli = FakeCLI.new([turn("sess-1", "A"), turn("sess-1", "B")])
    end
  end

  let(:cli) { provider.instance_variable_get(:@cli) }

  it "starts an agent on turn 1 (no resume) then resumes it on turn 2 with only the new turn" do
    m1 = user("first")
    provider.complete([m1], model: "x")
    expect(cli.calls[0][:resume]).to be_nil
    expect(cli.calls[0][:prompt]).to eq("first")

    messages = [m1, RubyLLM::Message.new(role: :assistant, content: "A"), user("second")]
    provider.complete(messages, model: "x")
    expect(cli.calls[1][:resume]).to eq("sess-1")
    expect(cli.calls[1][:prompt]).to eq("second")
  end

  it "tracks forwarded turns by identity, surviving with_instructions reordering" do
    m1 = user("first")
    provider.complete([m1], model: "x")

    # Simulate with_instructions prepending a system message and reordering @messages.
    system_message = RubyLLM::Message.new(role: :system, content: "be terse")
    m2 = user("second")
    provider.complete([system_message, m1, m2], model: "x")

    expect(cli.calls[1][:prompt]).to eq("second")
  end

  it "prepends system instructions on the first turn only" do
    system_message = RubyLLM::Message.new(role: :system, content: "be terse")
    provider.complete([system_message, user("first")], model: "x")
    expect(cli.calls[0][:prompt]).to eq("be terse\n\nfirst")
  end

  it "keeps separate Chats isolated (state lives on the provider instance)" do
    other = RubyLLM::Cursor::Provider.new(RubyLLM.config).tap { |p| p.cli = FakeCLI.new(turn("sess-2", "Z")) }
    provider.complete([user("first")], model: "x")
    other.complete([user("hello")], model: "x")
    expect(other.instance_variable_get(:@cli).calls[0][:resume]).to be_nil
  end
end
