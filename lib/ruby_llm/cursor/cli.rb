# frozen_string_literal: true

require "open3"
require "json"

module RubyLLM
  module Cursor
    # The only place that spawns a process. Builds the cursor-agent argv as an
    # array (never a shell string, so a prompt cannot inject commands), passes
    # the API key via the environment (never argv), and yields each parsed
    # NDJSON event to the block in order.
    class CLI
      DEFAULT_BIN = "cursor-agent"

      def initialize(config = nil)
        @config = config
      end

      # Yields each parsed event Hash to +on_event+. Raises a RubyLLM error on a
      # non-zero exit or a missing binary. Returns the Process::Status.
      def run(prompt:, model: nil, workspace: nil, mode: nil, resume: nil,
              api_key: nil, stream: false, force: false, &on_event)
        validate_workspace!(workspace)
        argv = build_argv(prompt: prompt, model: model, workspace: workspace,
                          mode: mode, resume: resume, stream: stream, force: force)
        spawn(build_env(api_key), argv, workspace, &on_event)
      end

      # Pure: the exact argv passed to the process. Exposed for testing the
      # injection-safety and conditional-flag contracts.
      def build_argv(prompt:, model:, workspace:, mode:, resume:, stream:, force:)
        argv = [binary, "-p", "--output-format", "stream-json", "--trust"]
        argv << "--stream-partial-output" if stream
        argv.push("--mode", mode.to_s) if %i[ask plan].include?(mode&.to_sym)
        argv << "--force" if force
        argv.push("--model", model.to_s) if present?(model)
        argv.push("--workspace", workspace.to_s) if present?(workspace)
        argv.push("--resume", resume.to_s) if present?(resume)
        argv << prompt.to_s # always the final positional arg; never interpolated into a shell
        argv
      end

      def binary
        path = @config&.cursor_agent_path if @config.respond_to?(:cursor_agent_path)
        present?(path) ? path.to_s : DEFAULT_BIN
      end

      private

      def build_env(api_key)
        env = {}
        env["CURSOR_API_KEY"] = api_key.to_s if present?(api_key)
        env
      end

      def validate_workspace!(workspace)
        return if workspace.nil?

        path = File.expand_path(workspace.to_s)
        return if File.directory?(path)

        raise RubyLLM::ConfigurationError,
              "cursor provider: workspace #{workspace.inspect} is not an existing directory"
      end

      def spawn(env, argv, workspace, &on_event)
        opts = {}
        opts[:chdir] = File.expand_path(workspace.to_s) if workspace

        Open3.popen3(env, *argv, **opts) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          # Drain stderr on a thread so a chatty CLI cannot deadlock the pipe.
          err_thread = Thread.new { stderr.read }

          stdout.each_line do |line|
            event = parse_line(line)
            on_event&.call(event) if event
          end

          status = wait_thr.value
          stderr_text = err_thread.value
          unless status.success?
            raise Errors.classify(status: status.exitstatus, stderr: stderr_text, api_key: env["CURSOR_API_KEY"])
          end

          status
        end
      rescue Errno::ENOENT
        raise RubyLLM::ConfigurationError,
              "cursor provider: '#{binary}' not found on PATH. Install the Cursor CLI and run " \
              "`cursor-agent login`, or set config.cursor_agent_path to the binary."
      end

      def parse_line(line)
        line = line.strip
        return nil if line.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
