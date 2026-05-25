# frozen_string_literal: true

RSpec.describe RubyLLM::Cursor do
  it "has a semver version string" do
    expect(RubyLLM::Cursor::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
