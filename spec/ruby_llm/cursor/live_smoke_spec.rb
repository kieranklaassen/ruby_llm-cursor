# frozen_string_literal: true

# Hits the real cursor-agent CLI. Excluded by default; run with:
#   CURSOR_LIVE=1 bundle exec rspec --tag live
RSpec.describe "Cursor live smoke", :live do
  it "answers a read-only question through the real cursor-agent CLI" do
    chat = RubyLLM.chat(model: "composer-2.5", provider: :cursor)
    message = chat.ask("Reply with exactly the single word: pong")
    expect(message).to be_a(RubyLLM::Message)
    expect(message.content.to_s.downcase).to include("pong")
  end
end
