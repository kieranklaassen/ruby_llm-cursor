# frozen_string_literal: true

RSpec.describe RubyLLM::Cursor::Errors do
  describe ".classify" do
    it "maps auth failures to UnauthorizedError" do
      error = described_class.classify(status: 1, stderr: "Error: not logged in. Run cursor-agent login")
      expect(error).to be_a(RubyLLM::UnauthorizedError)
    end

    it "maps rate limits to RateLimitError" do
      error = described_class.classify(status: 1, stderr: "rate limit exceeded, slow down")
      expect(error).to be_a(RubyLLM::RateLimitError)
    end

    it "maps unknown-model errors to BadRequestError" do
      stderr = "Cannot use this model: foo. Available models: composer-2.5, auto"
      expect(described_class.classify(status: 1, stderr: stderr)).to be_a(RubyLLM::BadRequestError)
    end

    it "falls back to ServerError" do
      expect(described_class.classify(status: 2, stderr: "something exploded")).to be_a(RubyLLM::ServerError)
    end

    it "uses a default message when stderr is empty" do
      error = described_class.classify(status: 7, stderr: "")
      expect(error.message).to include("status 7")
    end
  end

  describe ".scrub" do
    it "redacts the API key value" do
      out = described_class.scrub("boom value sk-secret-123 happened", "sk-secret-123")
      expect(out).not_to include("sk-secret-123")
      expect(out).to include("[REDACTED]")
    end

    it "drops lines that carry credentials" do
      out = described_class.scrub("line ok\ntoken: abc123\nmore ok", nil)
      expect(out).not_to include("abc123")
      expect(out).to include("line ok").and include("more ok")
    end
  end
end
