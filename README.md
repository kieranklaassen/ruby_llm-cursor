# ruby_llm-cursor

Chat with [Cursor's](https://cursor.com) coding agent through [RubyLLM](https://github.com/crmne/ruby_llm).

`ruby_llm-cursor` registers a `:cursor` provider that drives the local
`cursor-agent` CLI. Simple calls return a plain-text answer; streaming exposes
incremental text and thinking; and every Cursor agent event (tool calls, file
edits, shell, status) is available through an observational callback. One
`RubyLLM::Chat` is backed by one persistent Cursor agent session, so multi-turn
conversations Just Work.

## Why this exists

RubyLLM gives Ruby a single chat API across providers. Cursor ships a strong
coding agent (`composer-*` models) reachable from the `cursor-agent` CLI, but
there is no Ruby SDK. This gem bridges the two — without forking RubyLLM.

> **Cursor is an agent, not a plain chat model.** In its default `ask` mode it
> only reads and explains. If you opt into `:agent` mode it can **edit files and
> run shell commands** in its working directory. See [Safety](#safety).

## Install

```ruby
# Gemfile
gem "ruby_llm"
gem "ruby_llm-cursor"
```

Requires the Cursor CLI on your PATH:

```bash
# https://cursor.com/docs/cli
cursor-agent login        # or set CURSOR_API_KEY
```

## Configure

```ruby
require "ruby_llm-cursor"

RubyLLM.configure do |config|
  # Optional — if omitted, the gem relies on `cursor-agent login` credentials.
  config.cursor_api_key      = ENV["CURSOR_API_KEY"]
  # Optional overrides:
  config.cursor_agent_path   = "/usr/local/bin/cursor-agent" # default: cursor-agent on PATH
  config.cursor_default_cwd  = Dir.pwd                        # workspace the agent operates in
  config.cursor_default_model = "composer-2.5"
  config.cursor_mutation_mode = :ask                          # :ask | :plan | :agent (default :ask)
end
```

Any Cursor model id works without registry edits (`composer-2.5`, `auto`,
`gpt-5.5-high`, `claude-opus-4-7-high`, …). Run `cursor-agent models` to list them.

## Usage

### Ask a question

```ruby
chat = RubyLLM.chat(model: "composer-2.5", provider: :cursor)
chat.ask("What does the auth middleware do?").content
# => "It validates the JWT in the Authorization header and ..."
```

### Stream the answer

```ruby
chat.ask("Summarize this repo") do |chunk|
  print chunk.content      # incremental assistant text
end
```

### Multi-turn (one persistent agent)

```ruby
chat = RubyLLM.chat(model: "composer-2.5", provider: :cursor)
chat.ask("Find the bug in lib/parser.rb")
chat.ask("Now explain the fix")   # resumes the same Cursor session; only the new turn is sent
```

### Observe agent events

Subscribe to the raw Cursor event stream (tool calls, file edits, shell, status)
for full fidelity. These are observational and never trigger RubyLLM's own tool
loop:

```ruby
chat = RubyLLM.chat(model: "composer-2.5", provider: :cursor)
chat.with_params(cursor: { on_event: ->(event) { p event["type"] } })
chat.ask("Refactor the utils module", )
```

## Safety

`cursor_mutation_mode` (or a per-call `with_params(cursor: { mutation_mode: … })`)
controls what the agent may do:

| Mode      | Behavior                                                        |
|-----------|----------------------------------------------------------------|
| `:ask`    | **Default.** Read-only Q&A. No file edits, no shell.           |
| `:plan`   | Read-only analysis / planning. No edits.                       |
| `:agent`  | Full agent: **can edit files and run shell** in the workspace. |

`:agent` runs headless with auto-approval (`--force`), so use it only against a
working directory you trust. Set the workspace with `config.cursor_default_cwd`
or `with_params(cursor: { workspace: "/path/to/project" })`.

## Limitations

- **Local CLI only.** No Cloud Agents REST transport and no OpenAI-compatible
  proxy.
- **RubyLLM tools aren't run by Cursor.** `with_tool` is not forwarded; Cursor
  uses its own tools. (Mapping Ruby tools to Cursor MCP servers is future work.)
- **Chat-only.** No embeddings/images/moderation/transcription.
- **Token counts, not cost.** `Message` token fields are populated from Cursor's
  usage data; RubyLLM cost calculation does not apply (Cursor bills separately).
- **`with_fallback` is unsupported with `:cursor`.** Fallback re-resolves the
  provider, which discards the agent session.
- **A `Chat` is not thread-safe** for concurrent `ask` calls (session state is
  mutated per turn).
- **Session expiry is silent.** If a Cursor session id is no longer valid, the
  CLI starts a fresh session rather than erroring, so prior context is lost
  without a signal.

## Development

```bash
bundle install
bundle exec rspec          # unit tests (subprocess stubbed; :live excluded)
CURSOR_LIVE=1 bundle exec rspec --tag live   # hits the real cursor-agent CLI
bundle exec rubocop
```

## License

MIT
