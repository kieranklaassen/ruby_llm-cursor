---
title: "feat: ruby_llm-cursor — Cursor agent as a RubyLLM provider"
type: feat
status: active
date: 2026-05-24
deepened: 2026-05-24
---

# feat: ruby_llm-cursor — Cursor agent as a RubyLLM provider

## Summary

A standalone gem, `ruby_llm-cursor`, that registers a `:cursor` provider with RubyLLM (`~> 1.15`) so `RubyLLM.chat(model: "composer-2.5", provider: :cursor)` drives the local `cursor-agent` CLI. Simple use returns a plain-text assistant message. Power use streams incremental text and thinking through RubyLLM's normal streaming block, while *all* Cursor agent events (tool calls, file edits, shell, status) are surfaced to a dedicated observational event callback — and never placed on `Message#tool_calls`. One `Chat` maps to one persistent Cursor agent, so multi-turn conversation works from the first release.

---

## Problem Frame

RubyLLM gives Ruby a unified chat interface across model providers (OpenAI, Anthropic, Gemini, …). Cursor ships a powerful coding agent (`composer-*` models) reachable from the `cursor-agent` CLI and a TypeScript SDK, but there is **no Ruby SDK** and no way to reach it through RubyLLM. Ruby developers who already standardize on RubyLLM cannot talk to Cursor's agent without leaving the abstraction and shelling out by hand, hand-parsing NDJSON, and managing agent session state themselves.

The friction is sharpest for two cases: (1) asking Cursor's models codebase-aware questions from a Ruby app/script, and (2) driving Cursor's agent to do real work (edit files, run shell) while observing the event stream — both from the same `RubyLLM::Chat` ergonomics used for every other provider.

The core tension this plan must resolve: RubyLLM's `Chat` is **stateless request/response** (full history replayed each turn, one assistant `Message` returned, RubyLLM owns the tool-execution loop), while Cursor is a **stateful agent** (context keyed by agent id, sends only the new turn, runs its own internal tools and emits side effects on disk). The gem's job is to bridge that mismatch faithfully — and, because every other provider's `ask` is side-effect-free, to make the file-mutating nature explicit and opt-in rather than a silent surprise.

---

## Requirements

**Provider integration**
- R1. The gem registers a `:cursor` provider via `RubyLLM::Provider.register` on load, requiring no fork of and no edits to the `ruby_llm` gem.
- R2. `RubyLLM.chat(model: <any-cursor-model-id>, provider: :cursor)` resolves and is usable without adding entries to `ruby_llm`'s `models.json` (provider declares models-assumed-to-exist).
- R3. Provider-specific configuration (API key, CLI path, working directory, default model, mutation posture) is exposed through `RubyLLM.configure` using RubyLLM's standard provider-option registration.

**Chat behavior**
- R4. `chat.ask("…")` (non-streaming) returns a single assistant `Message` whose `content` is Cursor's final text result.
- R5. `chat.ask("…") { |chunk| … }` (streaming) yields `Chunk`s carrying incremental assistant text and thinking, and still returns the final assistant `Message`. The streamed chunks reflect the agent's live output (which may include exploratory preamble); the final `Message#content` is Cursor's `result` answer, so the two need not be byte-identical. (Verified during dogfooding: the CLI emits delta events plus a consolidated repeat — only deltas are streamed.)
- R6. Multi-turn: a single `Chat` instance maps to one persistent Cursor agent for its lifetime — the first turn starts an agent and captures its id; each later turn resumes that agent and forwards only the newest user turn (not the full replayed history). Turn tracking is robust to message-array reordering (e.g., `with_instructions` prepending system messages).
- R7. System instructions set via `with_instructions` are applied to the agent on the first turn and not re-sent on subsequent turns.

**Agentic event exposure**
- R8. Cursor's internal agent events (tool calls, file edits, shell commands, status, task milestones) are surfaced observationally to the caller through a dedicated event callback and are **never** placed on `Message#tool_calls`, so RubyLLM's tool-execution loop is not triggered. This is enforced as a tested invariant, not a convention.
- R9. The event callback gives power users full-fidelity, in-order access to each raw Cursor event, with a committed public API surface.

**Safety**
- R12. The file-mutating nature of the agent is explicit and controllable: the provider exposes a mutation posture (config + per-chat override). The default is the least-destructive mode the CLI supports; autonomous file edits require explicit opt-in. The behavior and default are documented prominently.

**Robustness**
- R10. Missing/unauthenticated CLI, Cursor error events, expired/invalid resume ids, and non-zero process exits surface as appropriate `RubyLLM` error types with actionable messages; secrets are never echoed in error text.
- R11. The gem ships with a README documenting setup, the chat/streaming/multi-turn usage, the event callback, the mutation posture, and known limitations (token/cost, working-dir side effects, `with_fallback` incompatibility).

---

## Scope Boundaries

- Local `cursor-agent` CLI transport only. The Cloud Agents REST API and the community OpenAI-compatible proxy shim are not implemented.
- RubyLLM-defined tools (`with_tool`) are **not** executed by the Cursor agent. Cursor brings its own tools; the provider does not translate RubyLLM tools into Cursor MCP servers.
- Chat completion only. Embeddings, image generation, moderation, and transcription provider methods are not implemented.
- Standard RubyLLM token-accounting and cost tracking are not guaranteed — Cursor bills separately and may not return OpenAI-style token counts; `Message` token/cost fields may be partial or nil.
- `with_fallback` is not supported in combination with `:cursor` in v1 (agent session state lives on the provider instance, which fallback re-resolution replaces). Documented and guarded, not silently broken.
- No changes to the `ruby_llm` gem itself; this repo depends on the released gem.

### Deferred to Follow-Up Work
- Map RubyLLM-defined tools to Cursor MCP servers so the agent can call Ruby-side tools: future iteration.
- Cloud Agents REST transport (async, repo-clone, artifacts/subagents): future iteration.
- Structured per-turn conversation history retrieval (Cursor's `conversation()` equivalent): future iteration.
- `cursor-agent` model discovery surfaced through `RubyLLM.models`: future iteration.
- Making agent state survive `with_fallback` (store state off the provider instance, keyed on the `Chat`): future iteration.
- Thread-safe concurrent `ask` on a single `Chat` (a mutex or rejection): future iteration; v1 documents single-threaded-per-Chat use.

---

## Context & Research

### Relevant Code and Patterns
*(All paths below prefixed `ruby_llm:` live in the `ruby_llm` dependency gem, read for pattern reference — they are not files in this repo. Unprefixed paths are files this gem will create.)*

- `ruby_llm: lib/ruby_llm/provider.rb` — base `Provider`. `complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &)` is the override seam. **The override MUST accept `tool_prefs:`** (Chat always passes it — see below) and a trailing block; prefer mirroring the full signature or accepting `**`. Class methods `register`, `assume_models_exist?`, `configuration_options`, `configuration_requirements`.
- `ruby_llm: lib/ruby_llm/chat.rb` — `complete_with_provider` (≈ line 201) calls `@provider.complete(messages, tools:, tool_prefs:, temperature:, model:, params:, headers:, schema:, thinking:, &)` — **`tool_prefs:` is always passed**. `with_model` (≈ line 74) does `@model, @provider = Models.resolve(...)` then `@connection = @provider.connection` — **the provider must respond to `#connection`** (nil is fine). `handle_tool_calls` (≈ line 244) — the loop to avoid — runs only when the returned `Message#tool_call?` is true. `with_instructions` / `append_system_instruction` / `replace_system_instruction` (≈ lines 342–359) **partition system messages to the FRONT of `@messages`**, reordering the array — index-based turn tracking is unsafe.
- `ruby_llm: lib/ruby_llm/models.rb` (`resolve`, ≈ lines 106–137) — builds the provider via `provider_class.new(config)` and returns a fresh instance **per `Chat`** (note: it constructs a throwaway `temp_instance` first, so `initialize` must be cheap and must not spawn processes). Auto-sets `assume_exists` when the provider is local or assumes-models-exist; unknown ids fall to `Model::Info.default`.
- `ruby_llm: lib/ruby_llm/fallback.rb` + `Chat` includes `Fallback` — `complete` is wrapped in `with_fallback_protection`; on `RateLimitError`/`ServerError` it calls `with_model(@fallback…)`, building a **new** provider instance. This is why agent state on the provider instance cannot survive fallback (see Scope Boundaries, Risks).
- `ruby_llm: lib/ruby_llm/providers/deepseek.rb`, `.../ollama.rb` — minimal provider subclass shape (`configuration_options`, `configuration_requirements`, `assume_models_exist?`).
- `ruby_llm: lib/ruby_llm/stream_accumulator.rb` — transport-agnostic; consumes `Chunk` objects (`add(chunk)`) and produces the final `Message` (`to_message(raw)`). **Reused for token/thinking assembly only.** Two caveats: (1) `to_message` builds `tool_calls` from any chunk where `chunk.tool_call?` — Cursor tool events must never become such chunks (R8); (2) `add` runs `<think>`-tag extraction on chunk **content**, rerouting any literal `<think>…</think>` substring into thinking — a real corruption risk for a coding agent, so message **content is assembled from the `result` event**, not from think-tag-parsed deltas (see U4).
- `ruby_llm: lib/ruby_llm/chunk.rb` — `Chunk < Message`; construct with `role:, model_id:, content:, thinking:, input_tokens:, …` as `OpenAI::Streaming#build_chunk` does (`ruby_llm: lib/ruby_llm/providers/openai/streaming.rb`).
- `ruby_llm: lib/ruby_llm/configuration.rb` — `register_provider_options` is invoked by `Provider.register`; declaring `configuration_options` is sufficient to get `config.cursor_*` accessors.
- `ruby_llm: lib/ruby_llm/error.rb` — `RubyLLM::Error`, `UnauthorizedError`, `RateLimitError`, `ServerError`, `ConfigurationError`, etc. Map Cursor failures to these.

### External References
- Cursor TypeScript SDK overview (`Agent.create/prompt/resume`, `run.stream()`, `SDKMessage` event types `system|assistant|thinking|tool_call|status|task|result`): https://cursor.com/docs/sdk/typescript — the SDK wraps the same `cursor-agent` CLI this gem targets.
- Cursor CLI headless mode (`cursor-agent -p --output-format stream-json` → NDJSON events; `CURSOR_API_KEY`; permission/force flags): https://cursor.com/docs/cli/headless and https://cursor.com/docs/cli/reference/parameters
- Local environment confirmed: `cursor-agent` installed at `~/.local/bin/cursor-agent` (`2026.05.20-2b5dd59`); Ruby 3.4.2; latest released `ruby_llm` is `1.15.0`.

### Institutional Learnings
- None on file (new standalone repo). Capture learnings during execution via `ce-compound`.

---

## Key Technical Decisions

- **Separate gem registering an external provider** (not a fork): RubyLLM supports `Provider.register`, and the per-`Chat` provider instance gives a home for agent state. Keeps `ruby_llm` pristine and publishable.
- **Override `complete` wholesale; do not touch RubyLLM's HTTP stack**: Cursor's transport is a subprocess, not HTTP. The override **must accept `tool_prefs:`** (Chat always passes it) or it raises `ArgumentError` on the first call. It bypasses `Connection`/`Streaming` and runs `cursor-agent` itself, reusing `StreamAccumulator` only for token/thinking assembly.
- **`api_base`/`connection` wiring is REQUIRED, not optional**: `Chat#with_model` assigns `@connection = @provider.connection` at construction, and base `Provider#initialize` → `Connection.new` calls `api_base` (whose default raises `NotImplementedError`). Decision: override `initialize` to set `@config`, skip building a real `Connection`, and expose `#connection` returning a no-op/nil; also define `api_base` returning a placeholder URL string as belt-and-suspenders. Asserted in U2 (construction must not raise and must not open a socket).
- **One `Chat` ↔ one persistent Cursor agent**: store `agent_id` and the set of already-forwarded user turns on the provider instance. Track forwarded turns by **message identity (object_id / stable marker), not an integer index**, because `with_instructions` reorders `@messages`. First turn starts the agent and applies system instructions. This is the load-bearing divergence from every other (stateless) provider.
- **`assume_models_exist? => true`**: any Cursor model id resolves via `Model::Info.default` with no `models.json` edits — mirrors the Ollama/local pattern. `initialize` stays cheap (no process spawn) because `Models.resolve` builds a throwaway instance.
- **Message content is assembled from the `result` event**, not from think-tag-parsed streamed deltas: avoids `StreamAccumulator`'s `<think>`-tag content corruption for a coding agent and removes the double-assembly ambiguity. Streamed text chunks are for live display; the final `content` comes from `result` (which may differ from the stream when the agent emits preamble). Only delta events are streamed — the CLI's consolidated repeat events are skipped to avoid duplication.
- **Cursor tool/edit/shell/status events are observational only**: surfaced via a single committed callback API; deliberately kept off `Message#tool_calls`. An invariant assertion (every chunk handed to the accumulator has `tool_call? == false`) backs R8.
- **Subprocess security discipline**: build argv as a Ruby **array** and spawn via `Open3` with `chdir:` and an explicit minimal `env:` — never `system(string)`/backticks (prevents prompt-driven command injection, R12/security P0). Pass the API key only in the subprocess `env`, never as an argv element. Pass an explicit minimal environment (key + PATH + what the CLI needs), not the full inherited parent env. Validate `cwd` is an existing absolute directory before spawning. Scrub the API-key value (and `token`/`secret`/`password` lines) from any stderr included in error messages.
- **A thin, mockable CLI transport seam**: one class spawns the process; tests stub it with recorded NDJSON fixtures (VCR/WebMock do not apply to subprocesses); one opt-in live smoke test exercises the real CLI.
- **`with_fallback` is unsupported with `:cursor`**: fallback re-resolves to a new provider instance that has no `agent_id`. v1 documents and guards this rather than silently losing context.
- **Token/cost best-effort**: populate `Message` token fields only if Cursor's `result` event provides them; otherwise nil and documented.

---

## Open Questions

### Resolved During Planning
- Where does agent session state live? — On the per-`Chat` provider instance (confirmed `Models.resolve` builds a fresh persisted instance per `Chat`).
- How do Cursor models resolve without a registry? — `assume_models_exist? => true` + `Model::Info.default`.
- Is `cursor-agent` available and what is the event format? — Installed locally; NDJSON via `-p --output-format stream-json`. Exact field names captured in the U3 spike.
- How are agentic events exposed without triggering RubyLLM's tool loop? — Dedicated observational callback + keep `Message#tool_calls` empty (tested invariant).
- Does the override need `tool_prefs:`? — Yes; Chat always passes it. Signature mirrors the base.
- Is the Connection/`api_base` wiring optional? — No; required for construction. Resolved via initialize override + `#connection` reader + placeholder `api_base`.

### Deferred to Implementation
- Exact `cursor-agent` flag spelling for resume, model selection, working directory, and mutation/permission posture; the precise NDJSON event field names (`type`, agent/thread id key, result key); and the resume-rejected/expired signal. **All captured in the U3 live spike before U4/U5 are built**, then pinned into fixtures. *(Tool-call event `args`/`result` shapes are explicitly unstable per Cursor docs — parse defensively.)*
- Whether to keep the agent process long-lived per `Chat` or spawn fresh per turn. Default lean: **resume-per-turn**; confirm against latency/behavior and working-dir stability in the U3 spike.
- Whether system instructions are best passed as a CLI flag, a first synthetic turn, or a rules mechanism — settled by the U3 spike, which must confirm at least one working injection path before U5.
- How `temperature`/`thinking`/`schema` RubyLLM params map (if at all) onto `cursor-agent` model params — map what exists, ignore the rest, document gaps.
- Recovery contract when a resume id is rejected mid-conversation: raise a specific error vs. restart-as-new-agent-with-warning (chosen in U7).

---

## Output Structure

    ruby_llm-cursor/
    ├── ruby_llm-cursor.gemspec
    ├── Gemfile
    ├── Rakefile
    ├── README.md
    ├── LICENSE
    ├── .rubocop.yml
    ├── .github/workflows/ci.yml
    ├── lib/
    │   ├── ruby_llm-cursor.rb            # require shim → ruby_llm/cursor
    │   └── ruby_llm/
    │       └── cursor/
    │           ├── version.rb
    │           ├── provider.rb           # RubyLLM::Cursor::Provider < RubyLLM::Provider
    │           ├── cli.rb                # subprocess transport seam (mockable): argv build, Open3 spawn, NDJSON
    │           ├── event_mapper.rb       # Cursor NDJSON event → Chunk / agent_id / result / passthrough
    │           └── errors.rb             # Cursor failure → RubyLLM error mapping + stderr scrubbing
    │       └── cursor.rb                 # entrypoint: requires + Provider.register(:cursor, …)
    └── spec/
        ├── spec_helper.rb
        ├── fixtures/
        │   ├── simple_qa.ndjson
        │   ├── thinking_and_tools.ndjson
        │   ├── multi_turn_resume.ndjson
        │   ├── resume_rejected.ndjson
        │   └── error_auth.ndjson
        ├── support/
        │   └── fake_cli.rb               # stub transport that replays a fixture
        └── ruby_llm/
            └── cursor/
                ├── provider_spec.rb
                ├── cli_spec.rb
                ├── event_mapper_spec.rb
                ├── multi_turn_spec.rb
                ├── errors_spec.rb
                └── live_smoke_spec.rb     # tagged :live, skipped without CLI + key

*Scope declaration, not a constraint. `event_mapper.rb` and `errors.rb` are kept as separate units because the fixture-based test strategy benefits from testing mapping and error-classification in isolation; the implementer may inline them if that proves simpler. Per-unit `Files:` lists remain authoritative.*

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Multi-turn flow, one `Chat` ↔ one Cursor agent:

```mermaid
sequenceDiagram
    participant App as RubyLLM::Chat
    participant P as Cursor::Provider (per-Chat)
    participant CLI as Cursor::CLI
    participant CA as cursor-agent (subprocess)

    App->>P: complete(messages, tool_prefs:, &block)  %% turn 1
    P->>P: new turns = messages NOT yet forwarded (by identity)
    P->>P: agent_id nil? → start (apply system instructions)
    P->>CLI: run(prompt, model, cwd, mutation_mode, resume: nil)  %% argv ARRAY, key via env
    CLI->>CA: Open3 spawn `-p --output-format stream-json`
    CA-->>CLI: NDJSON: system(agent_id) / thinking / assistant / tool_call / result
    loop each event
        CLI-->>P: parsed event
        P->>P: capture agent_id (system); build text/thinking Chunk
        P-->>App: block.call(chunk)  %% streaming display only
        P->>P: accumulator.add(chunk) [tool_call? MUST be false]; raw event → on_event callback
    end
    P-->>App: final Message (content = result text; tool_calls EMPTY)
    P->>P: mark forwarded turns; store agent_id

    App->>P: complete(messages, tool_prefs:, &block)  %% turn 2
    P->>CLI: run(latest user turn, resume: agent_id)
    Note over P,CA: only the newest turn forwarded; if resume rejected → U7 recovery contract
```

Event mapping (directional):

| Cursor event `type` | Maps to | Notes |
|---|---|---|
| `system` (init) | capture `agent_id`, model, tools | not streamed as content |
| `assistant` / text-delta | `Chunk(content: …)` for live display | streamed; NOT the source of final content |
| `thinking` | `Chunk(thinking: …)` | streamed + accumulated |
| `tool_call` / edit / shell | raw → `on_event` callback | **never** `Message#tool_calls` |
| `status` / `task` | raw → `on_event` callback | observational |
| `result` | **final content** + (optional usage/duration) | closes the turn |
| error / resume-rejected / non-zero exit | raise mapped `RubyLLM` error (scrubbed) | see U7 |

---

## Implementation Units

### U1. Gem scaffold and packaging

**Goal:** A loadable, testable gem skeleton that depends on `ruby_llm ~> 1.15` and wires up CI/lint/test, with no provider behavior yet.

**Requirements:** Foundation only — satisfies no R directly; prerequisite for all others.

**Dependencies:** None

**Files:**
- Create: `ruby_llm-cursor.gemspec`, `Gemfile`, `Rakefile`, `LICENSE`, `.rubocop.yml`, `.github/workflows/ci.yml`, `.gitignore`
- Create: `lib/ruby_llm-cursor.rb`, `lib/ruby_llm/cursor.rb`, `lib/ruby_llm/cursor/version.rb`
- Create: `spec/spec_helper.rb`
- Test: `spec/ruby_llm/cursor/version_spec.rb`

**Approach:**
- `bundler`-style gem layout. Gemspec: runtime dep `ruby_llm ~> 1.15`; dev deps `rspec`, `rubocop`; required Ruby `>= 3.1`.
- `lib/ruby_llm-cursor.rb` is a hyphen→slash require shim that loads `ruby_llm/cursor`.
- `lib/ruby_llm/cursor.rb` requires submodules and (in U2) registers the provider; for U1 it just defines the module and version.
- CI: install deps, run rubocop + rspec on the supported Ruby matrix.

**Patterns to follow:** Conventional gem structure; `ruby_llm`'s own gemspec/Rakefile for dev-dependency choices.

**Test scenarios:**
- Happy path: `require "ruby_llm-cursor"` loads without error and `RubyLLM::Cursor::VERSION` is a frozen semver string.

**Verification:** `bundle install`, `bundle exec rspec`, and `bundle exec rubocop` all succeed on a clean checkout.

---

### U2. Provider registration, construction safety, and model resolution

**Goal:** A `RubyLLM::Cursor::Provider` registered as `:cursor` that constructs without HTTP, resolves any Cursor model id, and exposes configuration, with `complete` still stubbed.

**Requirements:** R1, R2, R3

**Dependencies:** U1

**Files:**
- Create: `lib/ruby_llm/cursor/provider.rb`
- Modify: `lib/ruby_llm/cursor.rb` (call `RubyLLM::Provider.register(:cursor, RubyLLM::Cursor::Provider)`)
- Test: `spec/ruby_llm/cursor/provider_spec.rb`

**Approach:**
- `Provider < RubyLLM::Provider`. Class methods: `configuration_options` → `%i[cursor_api_key cursor_agent_path cursor_default_cwd cursor_default_model cursor_mutation_mode]`; `assume_models_exist? => true`; `configuration_requirements => []` (CLI may be authenticated via `cursor-agent login`; validate at call time in U3).
- **Override `initialize`** to set `@config` and **not** build a `Connection`; expose `#connection` returning nil (or a no-op) so `Chat#with_model`'s `@connection = @provider.connection` is safe. Also define `api_base` returning a placeholder URL string so any base-class path that reaches it does not raise. Keep `initialize` cheap — no process spawn (`Models.resolve` builds a throwaway instance).
- Keep `complete` raising `NotImplementedError` until U4.

**Patterns to follow:** `ruby_llm: lib/ruby_llm/providers/ollama.rb` (assume-exists), `deepseek.rb` (config options); `ruby_llm: lib/ruby_llm/chat.rb#with_model` for the `connection` coupling.

**Test scenarios:**
- Happy path: after load, `RubyLLM::Provider.providers[:cursor]` is the provider class.
- Happy path: `RubyLLM.chat(model: "composer-2.5", provider: :cursor)` constructs a usable `Chat` (model resolves via `Model::Info.default`, no `models.json` entry).
- Integration: constructing the `Chat` does **not** raise and does **not** open a network socket (assert `api_base`/`connection` path is inert); `provider.connection` is nil/no-op.
- Happy path: `RubyLLM.configure { |c| c.cursor_api_key = "x"; c.cursor_default_cwd = "/tmp"; c.cursor_mutation_mode = :ask }` round-trips.
- Edge case: resolving `:cursor` with an unknown model id does not raise `ModelNotFoundError`.

**Verification:** A `Chat` against `:cursor` is constructable and configurable; no HTTP connection attempted; `connection` reader present.

---

### U3. CLI transport seam + live capture spike (subprocess, NDJSON, security discipline)

**Goal:** A single mockable class that safely builds the `cursor-agent` argv, spawns it, and yields parsed NDJSON events in order — and, first, a live capture that pins the real flag spelling and event shapes that U4/U5 depend on.

**Requirements:** R10 (partial), R12 (mutation flag), foundation for R4–R9

**Dependencies:** U2

**Files:**
- Create: `lib/ruby_llm/cursor/cli.rb`
- Test: `spec/ruby_llm/cursor/cli_spec.rb`, `spec/support/fake_cli.rb`, `spec/fixtures/simple_qa.ndjson`

**Approach:**
- **Spike first (gate, do before U4/U5):** run the real `cursor-agent -p --output-format stream-json` once for (a) a single Q&A, (b) a resumed second turn, (c) a system-instruction injection attempt, and (d) the available mutation/permission flags. Record actual event field names, the agent/thread-id key, the result key, the resume flag spelling, and the resume-rejected signal. Save real captures as fixtures. If no system-instruction injection path works, surface it before building U5.
- `CLI#run(prompt:, model:, cwd:, mutation_mode:, resume:, api_key:, &on_event)` — resolves the binary (config `cursor_agent_path` or `cursor-agent` on `PATH`); builds argv as a **Ruby array** (`-p --output-format stream-json` plus model/resume/cwd/mutation flags); spawns via `Open3` with `chdir: cwd` and an explicit minimal `env:` (`CURSOR_API_KEY` + `PATH` + required vars only — do not inherit the full parent env). Streams stdout line-by-line, parses each line as JSON, yields each event to `on_event`.
- **Security (P0):** never build a shell command string; never put the API key in argv. Validate `cwd` is an existing absolute directory before spawning, else `RubyLLM::ConfigurationError`.
- On binary-not-found → `RubyLLM::ConfigurationError` with install/login guidance. Surface child exit status + stderr to the caller for U7.

**Execution note:** Do the live capture spike before writing fixtures or U4/U5; pin fixtures to real output.

**Patterns to follow:** Dependency-injected transport boundary; `Open3.popen3(*argv, chdir:, env:)` line iteration.

**Test scenarios:**
- Happy path: given a fixture stream, `run` yields each event hash in order.
- Security (Integration): a prompt containing `; echo INJECTED` (and `$()`, backticks) is passed as a single argv element — assert the constructed argv array, and that no shell interpretation occurs.
- Security: the API key never appears in the constructed argv; it is placed only in the `env` hash.
- Edge case: argv includes the resume flag only when `resume:` is non-nil, the model selector only when `model:` is present, and the mutation flag per `mutation_mode`.
- Edge case: `cwd` that does not exist / is not absolute → `RubyLLM::ConfigurationError`.
- Edge case: a partial/blank trailing line is skipped; a malformed (non-JSON) line follows the chosen skip-vs-raise behavior (asserted).
- Error path: binary not found → `RubyLLM::ConfigurationError` mentioning `cursor-agent` setup.

**Verification:** With `FakeCLI`, the provider is fully fixture-driven; argv is array-built with the key only in env; live capture fixtures exist and match the real CLI.

---

### U4. Event→Chunk mapping and single-turn `complete`

**Goal:** Implement `complete` for one turn: consume CLI events, stream text/thinking chunks (when a block is given), assemble final content from the `result` event, and return the final assistant `Message` — with `tool_calls` provably empty.

**Requirements:** R4, R5, R8

**Dependencies:** U3

**Files:**
- Create: `lib/ruby_llm/cursor/event_mapper.rb`
- Modify: `lib/ruby_llm/cursor/provider.rb` (real `complete`, accepting `tool_prefs:`)
- Test: `spec/ruby_llm/cursor/event_mapper_spec.rb`, `spec/fixtures/thinking_and_tools.ndjson`

**Approach:**
- `EventMapper` converts a Cursor event hash into: a display `Chunk` (`assistant` text, `thinking`), an `agent_id` capture (`system`), a final-result payload (`result`), or passthrough (tool/status/task → U6).
- `complete(messages, tools:, tool_prefs:, temperature:, model:, params:, headers:, schema:, thinking:, &block)`: **accept `tool_prefs:`** (mirror the base signature) to avoid `ArgumentError`. For each CLI event: map it; for display chunks, call `block.call(chunk)` when a block was given, and `accumulator.add(chunk)` for thinking/usage; capture `agent_id`; on `result`, record the final text/usage.
- Build the returned `Message`: **content from the `result` text** (not from think-tag-parsed deltas); thinking/usage from the accumulator. Assert every chunk added to the accumulator has `tool_call? == false`. Non-streaming (`block` nil): identical consumption, no `block.call`.

**Technical design:** *(directional)* `Chunk.new(role: :assistant, model_id:, content:, thinking: Thinking.build(...))` mirrors `OpenAI::Streaming#build_chunk`; see the event table above.

**Patterns to follow:** `ruby_llm: lib/ruby_llm/providers/openai/streaming.rb#build_chunk`; `ruby_llm: lib/ruby_llm/stream_accumulator.rb`.

**Test scenarios:**
- Happy path (non-streaming): a simple-Q&A fixture yields a `Message` with `role: :assistant`, `content` == result text, `tool_call?` false.
- Happy path (streaming): the same fixture invokes the block with ≥1 display `Chunk`; **streamed deltas are not duplicated by the consolidated event** (R5); final `Message#content` comes from `result`; return value is the final `Message`.
- Edge case: `thinking` events accumulate into `Message#thinking`, not `content`.
- Edge case (content fidelity): assistant text containing literal `<think>…</think>` and code fences survives **intact** in final content (because content comes from `result`, bypassing think-tag extraction).
- Edge case: a stream with `tool_call` events still returns `tool_call? == false` (R8 invariant) and RubyLLM does not enter `handle_tool_calls`.
- Edge case: empty/zero-text result → `content` nil/empty without raising.
- Integration: `agent_id` from the `system` event is stored on the provider instance for U5.

**Verification:** `chat.ask` and `chat.ask { |c| … }` both work against fixtures; content is faithful even with tag-like text; `tool_calls` empty.

---

### U5. Multi-turn resume state machine

**Goal:** Map one `Chat` to one persistent agent: start on first turn (with system instructions), resume on later turns, forward only the newest user turn, robust to message reordering.

**Requirements:** R6, R7

**Dependencies:** U4

**Files:**
- Modify: `lib/ruby_llm/cursor/provider.rb` (turn-diffing by identity + resume + system-instruction handling)
- Test: `spec/ruby_llm/cursor/multi_turn_spec.rb`, `spec/fixtures/multi_turn_resume.ndjson`

**Approach:**
- Track `@agent_id` and the set of **already-forwarded user-message identities** (object_id or a stable per-message marker) on the provider instance — **not** an integer `messages.size` index, because `with_instructions` prepends system messages and reorders the array.
- Each `complete`: compute user messages not yet forwarded; derive the prompt from the newest; pass `resume: @agent_id` (nil on first turn). First turn: apply any `system` message as the agent's instructions (path confirmed by the U3 spike); never resend it.
- After a successful turn, mark those turns forwarded and persist `agent_id`. Default process model: resume-per-turn (confirmed in U3).
- Guards: if no new user turn is present, raise/return predictably (non-silent, asserted). Document that a `Chat` is **not thread-safe** for concurrent `ask` (state mutation is unguarded in v1). Working directory must stay stable across turns for a given `agent_id`; document and assert the cwd used on turn 2 matches turn 1.

**Technical design:** *(directional)* see the sequence diagram.

**Patterns to follow:** `ruby_llm: lib/ruby_llm/chat.rb` message/role handling and `with_instructions` reordering; provider instance is per-`Chat` (`ruby_llm: lib/ruby_llm/models.rb#resolve`).

**Test scenarios:**
- Happy path: turn 1 starts an agent (no resume) and captures `agent_id`; turn 2 forwards only the newest user message with the captured `agent_id` as resume.
- Happy path: a `system` instruction is included on turn 1 and absent on turn 2.
- Edge case (reordering): calling `with_instructions` between turns prepends a system message; assert only the genuine new user turn is forwarded on the next `ask` (identity-based tracking, not index).
- Edge case: two sequential `ask`s never replay earlier user turns to the CLI.
- Edge case: a fresh `Chat` (new provider instance) starts its own agent — no state bleed.
- Edge case: turn 2 uses the same working directory as turn 1.
- Error path: a turn with no new user message raises/echoes a clear, non-silent result (asserted).

**Verification:** A two-turn scripted conversation shows turn 2 carries resume + only the latest turn, survives a mid-conversation `with_instructions`, and keeps a stable cwd; separate `Chat`s stay isolated.

---

### U6. Observational agentic-event passthrough

**Goal:** Expose Cursor's tool/edit/shell/status/task events to callers in order through a committed callback API, without ever populating `Message#tool_calls`.

**Requirements:** R8, R9

**Dependencies:** U4

**Files:**
- Modify: `lib/ruby_llm/cursor/provider.rb`, `lib/ruby_llm/cursor/event_mapper.rb`
- Test: `spec/ruby_llm/cursor/event_mapper_spec.rb` (extend), `spec/ruby_llm/cursor/provider_spec.rb` (extend)

**Approach:**
- Commit to one public API for the callback and verify it against the real `complete(params:)` passthrough. Default: `chat.with_params(cursor: { on_event: ->(event) { … } })`, read from the `params` arg in `complete`. Document that `with_params` **replaces `@params` wholesale** and persists across all turns of the `Chat` (namespace under the `cursor:` key; coexist with other params by reading only that key). Invoke the callback with each raw Cursor event (defensively typed — tool `args`/`result` shapes are unstable).
- **Do not** add a second event representation. The optional "forward a human-readable trace through the streaming block" idea is dropped for v1 — it duplicates event delivery and risks leaking tool events into the accumulator. Raw `on_event` is the single power-user surface.
- Reassert R8 as an invariant: any chunk handed to the accumulator has `tool_call? == false`; `Message#tool_calls` is always empty for this provider.

**Patterns to follow:** RubyLLM `params` flow (`ruby_llm: lib/ruby_llm/chat.rb#complete_with_provider` → provider `complete(params:)`).

**Test scenarios:**
- Happy path: with `on_event` supplied via `with_params(cursor: {...})`, every raw Cursor event in a fixture is delivered to the callback in stream order — assert the registration path works (not just delivery).
- Happy path: the callback persists across multiple turns of the same `Chat` and coexists with other `with_params` entries.
- Happy path: without a callback, streams with tool/edit/status events complete normally and return the final `Message`.
- Edge case: a tool event with an unexpected/unknown `args` shape is delivered without raising.
- Integration (R8 regression): a fixture rich in tool_call events yields `Message#tool_call? == false`; assert the accumulator's tool_calls hash stays empty.

**Verification:** Power users observe full agent activity via one committed callback; default users get clean text/thinking; no RubyLLM tool execution; `tool_calls` provably empty.

---

### U7. Error mapping and failure modes

**Goal:** Translate Cursor error events, auth failures, expired/invalid resume ids, and non-zero exits into appropriate `RubyLLM` error types with actionable, secret-free messages.

**Requirements:** R10

**Dependencies:** U3, U4

**Files:**
- Create: `lib/ruby_llm/cursor/errors.rb`
- Modify: `lib/ruby_llm/cursor/provider.rb`, `lib/ruby_llm/cursor/cli.rb`
- Test: `spec/ruby_llm/cursor/errors_spec.rb`, `spec/fixtures/error_auth.ndjson`, `spec/fixtures/resume_rejected.ndjson`

**Approach:**
- Map: auth/credential failure → `RubyLLM::UnauthorizedError`; rate/usage limit → `RubyLLM::RateLimitError`; missing/!executable binary or invalid cwd → `RubyLLM::ConfigurationError`; **invalid/expired resume id → a dedicated error** (recovery contract: raise a specific `RubyLLM::Error` subclass that names the lost-context situation; do **not** silently start a fresh agent); generic Cursor error/non-zero exit → `RubyLLM::ServerError`/`RubyLLM::Error` carrying Cursor's message + a **scrubbed** stderr tail.
- **Secret scrubbing:** before including stderr in any message, redact the `CURSOR_API_KEY` value and strip lines containing `token`/`key`/`secret`/`password`.
- Detection sources: Cursor `error`-type events, the resume-rejected signal (captured in U3), exit status, stderr. Centralize in `errors.rb`. A failure mid-stream raises rather than returning a truncated `Message`.

**Patterns to follow:** `ruby_llm: lib/ruby_llm/error.rb` hierarchy and message style.

**Test scenarios:**
- Error path: auth-failure fixture → `RubyLLM::UnauthorizedError` pointing at API key / `cursor-agent login`.
- Error path: rate-limit error event → `RubyLLM::RateLimitError`.
- Error path: resume-rejected fixture → the dedicated expired-resume error, message explains context was lost; no silent new agent.
- Error path: non-zero exit with stderr, no structured error → `RubyLLM::Error`/`ServerError` with a **scrubbed** stderr tail.
- Security: an error raised with a key-containing stderr payload does **not** include the key value in the message.
- Error path: missing binary → `RubyLLM::ConfigurationError`.
- Edge case: an error event after partial assistant text still raises rather than returning the partial message.

**Verification:** Each failure class maps to the documented error type and message; resume-expiry has an explicit contract; no secret leaks; no swallowed failures.

---

### U8. Safety posture, documentation, and live smoke test

**Goal:** Make the mutation posture real and default-safe, ship a README that gets a user productive, and prove the real CLI path with an opt-in live test.

**Requirements:** R11, R12 (and live validation of R4–R10)

**Dependencies:** U2–U7

**Files:**
- Modify: `lib/ruby_llm/cursor/provider.rb`, `lib/ruby_llm/cursor/cli.rb` (wire `cursor_mutation_mode` + per-chat override to the CLI flag captured in U3)
- Create: `README.md`
- Create: `spec/ruby_llm/cursor/live_smoke_spec.rb` (tagged `:live`)
- Modify: `spec/spec_helper.rb` (exclude `:live` by default)

**Approach:**
- **Mutation posture (R12):** map `cursor_mutation_mode` (config) and a per-chat override (`with_params(cursor: { mutation_mode: … })`) to the CLI's permission/force flag discovered in U3. Default to the least-destructive supported mode; autonomous edits require explicit opt-in. If the CLI offers no read-only mode, document the residual risk prominently and still require opt-in for `--force`-style autonomy.
- README: install; configure (`cursor_api_key` / `cursor-agent login`, `cursor_default_cwd`, `cursor_mutation_mode`); basic `ask`; streaming; multi-turn; the `on_event` callback; and a **Limitations** section (token/cost not standard; the agent edits real files in the working dir; local-CLI only; RubyLLM tools not run by Cursor; `with_fallback` unsupported; `Chat` not thread-safe for concurrent `ask`).
- Live smoke test: skipped unless `cursor-agent` is on PATH and a key/login exists; performs a trivial, **read-only/non-mutating** `ask` and asserts a non-empty assistant `Message`.

**Execution note:** Author docs from the implemented API, not this plan's sketch — reconcile any drift.

**Test scenarios:**
- Happy path: default `mutation_mode` produces the least-destructive CLI flag; opt-in produces the autonomous-edit flag (assert the argv flag per mode).
- Happy path (live, opt-in): with CLI + credentials, a read-only `ask` returns a non-empty assistant `Message`.
- Test expectation: README has no executable assertions; covered by review.

**Verification:** Default `rspec` is green and excludes `:live`; mutation flag matches mode; `--tag live` against the real CLI returns a real answer; README matches the shipped API.

---

## System-Wide Impact

- **Interaction graph:** The provider plugs into `RubyLLM::Chat` via `complete` (accepting `tool_prefs:`). Reused RubyLLM internals: `StreamAccumulator` (thinking/usage only), `Chunk`/`Message`/`Thinking`, the error hierarchy, `Provider.register`/config registration. `Connection`/`Streaming`/tool-loop are deliberately bypassed; `#connection` returns nil for `Chat#with_model`.
- **Error propagation:** CLI/process failures originate in `cli.rb`, are classified (and stderr-scrubbed) in `errors.rb`, and surface from `complete` as `RubyLLM::*` errors — including a dedicated expired-resume error.
- **State lifecycle risks:** Agent state (`@agent_id`, forwarded-turn set) is per-`Chat` provider instance. Risks: history desync if the caller mutates `@messages` (mitigated by identity-based tracking + the no-new-turn guard); state loss under `with_fallback` (unsupported + documented); concurrency corruption under multi-threaded `ask` on one `Chat` (documented not-thread-safe); orphaned agents if a process is killed mid-turn (resume-per-turn limits the leak surface); working-dir drift across turns (pinned + asserted).
- **API surface parity:** Standard chat surface (`ask`, streaming block, `with_instructions`, `with_params`). Omits embeddings/images/moderation/transcription (documented).
- **Integration coverage:** Highest-value cross-layer guarantee — "tool events never reach `Message#tool_calls`" — covered by a fixture-driven regression (U6) and an accumulator invariant assertion (U4).
- **Unchanged invariants:** The `ruby_llm` gem is untouched; purely additive registration. No change to other providers.

---

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Prompt-driven command injection via shell string | Med | High | argv **array** + `Open3` only; never `system(string)`; injection regression test (U3) |
| API key leaked via argv / `ps` / logs | Med | High | Key only in subprocess `env`; never argv; stderr scrubbed in errors; tests assert (U3, U7) |
| `complete` signature missing `tool_prefs:` → `ArgumentError` | High | High | Override mirrors base signature incl. `tool_prefs:` (U4); first-call test |
| `api_base`/`connection` treated as optional → construction raises | High | High | initialize override + `#connection` reader + placeholder `api_base`; no-socket construction test (U2) |
| High-water mark breaks under `with_instructions` reordering | Med | High | Track forwarded turns by message identity, not index; reordering test (U5) |
| `with_fallback` silently drops agent state | Med | Med | Unsupported + documented + guarded; do not combine with `:cursor` (U5/U8) |
| `StreamAccumulator` strips `<think>` from coding-agent content | Med | Med | Final content from `result` event, bypassing think-tag extraction; fidelity test (U4) |
| Cursor NDJSON field names / resume flag differ from assumptions | High | Med | U3 live spike captures real output before U4/U5; fixtures pinned; parse defensively |
| Resume id expires/rejected mid-conversation | Med | Med | Dedicated error + recovery contract + fixture (U7) |
| Agent edits files unexpectedly on a "chat" call | Med | High | R12 mutation posture, default least-destructive, opt-in for edits; prominent docs; read-only live test |
| Concurrent `ask` on one `Chat` corrupts state | Low | Med | Documented not-thread-safe; mutex deferred to follow-up |
| Subprocess inherits full parent env (secret exposure) | Med | Med | Explicit minimal `env` (key + PATH + required), not inherited (U3) |
| `cwd` set to `/` or `~` directing edits broadly | Med | High | Validate absolute existing dir; document scoping to a project dir (U3/U8) |
| Token/cost fields nil break callers expecting numbers | Low | Low | Best-effort accounting documented; leave nil rather than fabricate |
| No GitHub remote yet → `/lfg` cannot push/PR | High | Low | Create remote at handoff or stop at a local commit; surfaced before the push step |

---

## Alternative Approaches Considered

- **Fork `ruby_llm` and add the provider in-tree:** rejected — permanent upstream divergence, not publishable; `Provider.register` makes a fork unnecessary.
- **Point RubyLLM's OpenAI provider at a community OpenAI-compatible Cursor proxy:** rejected for v1 — zero event fidelity, third-party dependency, defeats the event-exposure goal.
- **Cloud Agents REST transport:** deferred — async, clones a repo into a VM, wrong shape for interactive local chat; revisit as a second transport.
- **Single-shot only (no multi-turn) for v1:** rejected per the brainstorm — multi-turn is the real conversational experience and was chosen up front. The feasibility risk (unverified resume semantics) is mitigated by gating U4/U5 behind the U3 live-capture spike rather than by dropping multi-turn.
- **Default to autonomous edits (no safety posture):** rejected — silently mutating files on a `chat.ask` violates the request/response mental model every other provider upholds; R12 makes edits opt-in.

---

## Documentation / Operational Notes
- README is U8's deliverable; must cover the mutation posture and the `with_fallback`/thread-safety limitations.
- Pin the tested `cursor-agent` CLI version in the README; the argv surface lives only in `cli.rb` to absorb CLI drift.

---

## Sources & References
- Brainstorm decisions (in-session; no requirements doc was written): both-progressively intent, separate-gem build target, local-CLI transport, multi-turn-from-start.
- Cursor SDK / CLI: https://cursor.com/docs/sdk/typescript · https://cursor.com/docs/cli/headless · https://cursor.com/docs/cli/reference/parameters
- RubyLLM dependency internals (pattern references): `ruby_llm: lib/ruby_llm/provider.rb`, `.../chat.rb`, `.../models.rb`, `.../fallback.rb`, `.../stream_accumulator.rb`, `.../chunk.rb`, `.../error.rb`, `.../providers/ollama.rb`, `.../providers/openai/streaming.rb`
- Document review (2026-05-24): integrated findings from coherence, feasibility, product-lens, security-lens, scope-guardian, and adversarial reviewers.
