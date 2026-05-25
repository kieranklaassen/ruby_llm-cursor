# frozen_string_literal: true

RSpec.describe RubyLLM::Cursor::CLI do
  subject(:cli) { described_class.new(RubyLLM.config) }

  describe "#build_argv" do
    def argv(**overrides)
      defaults = { prompt: "hi", model: nil, workspace: nil, mode: nil, resume: nil, stream: false, force: false }
      cli.build_argv(**defaults.merge(overrides))
    end

    it "always uses headless stream-json and passes the prompt as the final single arg" do
      result = argv(prompt: "explain auth")
      expect(result).to include("-p", "--output-format", "stream-json", "--trust")
      expect(result.last).to eq("explain auth")
    end

    it "keeps a malicious prompt as one argument (no shell interpolation)" do
      payload = "; rm -rf ~ && echo $(whoami)"
      expect(argv(prompt: payload).last).to eq(payload)
    end

    it "adds --resume only when a session id is present" do
      expect(argv(resume: nil)).not_to include("--resume")
      expect(argv(resume: "sess-1")).to include("--resume", "sess-1")
    end

    it "adds --model and --workspace only when present" do
      expect(argv).not_to include("--model")
      expect(argv(model: "composer-2.5")).to include("--model", "composer-2.5")
    end

    it "maps :ask/:plan to --mode but :agent (nil) to no --mode flag" do
      expect(argv(mode: :ask)).to include("--mode", "ask")
      expect(argv(mode: :plan)).to include("--mode", "plan")
      expect(argv(mode: nil)).not_to include("--mode")
    end

    it "adds --stream-partial-output and --force conditionally" do
      expect(argv(stream: true)).to include("--stream-partial-output")
      expect(argv(stream: false)).not_to include("--stream-partial-output")
      expect(argv(force: true)).to include("--force")
    end

    it "never carries the API key (it travels via env, not argv)" do
      RubyLLM.configure { |c| c.cursor_api_key = "sk-super-secret" }
      expect(argv.join(" ")).not_to include("sk-super-secret")
    end
  end

  describe "#run validation" do
    it "raises ConfigurationError for a non-existent workspace" do
      expect { cli.run(prompt: "hi", workspace: "/no/such/dir/xyz-12345") {} }
        .to raise_error(RubyLLM::ConfigurationError, /not an existing directory/)
    end

    it "raises ConfigurationError when the binary is missing" do
      RubyLLM.configure { |c| c.cursor_agent_path = "/nonexistent/cursor-agent-zzz" }
      expect { cli.run(prompt: "hi", workspace: Dir.pwd) {} }
        .to raise_error(RubyLLM::ConfigurationError, /cursor-agent|not found/)
    end
  end
end
