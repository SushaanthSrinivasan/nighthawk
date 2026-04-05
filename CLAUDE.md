# nighthawk — AI Terminal Autocomplete

Open-source, local-first, cross-platform terminal autocomplete with inline ghost text. Spiritual successor to Fig. Rust daemon + thin shell plugins communicating over IPC. Zero config, zero login, zero telemetry.

## Architecture

```
┌──────────────────────────────────┐
│  Terminal (any emulator)         │
│  ┌────────────────────────────┐  │
│  │ Shell plugin (~50 lines)   │  │
│  │ Reads buffer, renders      │  │
│  │ ghost text via ANSI ESC    │  │
│  └───────────┬────────────────┘  │
└──────────────┼───────────────────┘
               │ JSON + newline over Unix socket / named pipe
┌──────────────▼───────────────────┐
│  nighthawk-daemon (Rust)         │
│                                  │
│  PredictionEngine                │
│  ├─ Tier 0: History prefix <1ms  │
│  ├─ Tier 1: Spec lookup   <1ms  │
│  ├─ Tier 2: Local LLM   ~500ms  │  (via ollama/llama.cpp/vllm, feature-gated)
│  └─ Tier 3: Cloud API   ~500ms  │  (future, BYOK)
│                                  │
│  Spec sources:                   │
│  ├─ withfig/autocomplete (689)   │
│  ├─ --help auto-parser           │
│  └─ community specs              │
└──────────────────────────────────┘
```

## Module map

Single crate published as `nighthawk` on crates.io. Install via `cargo install nighthawk`. Produces two binaries: `nh` (CLI) and `nighthawk-daemon`.

- **`src/proto/`** — IPC message types. `CompletionRequest`, `CompletionResponse`, `Suggestion`, `Shell`, `SuggestionSource`, `default_socket_path()`.
- **`src/daemon/`** — Background daemon logic. All prediction logic, spec loading, history indexing, IPC server. This is where 90% of the logic lives.
- **`src/cli/`** — User-facing CLI (`nh start`, `nh stop`, `nh status`, `nh setup zsh`, `nh complete "git ch"`).
- **`src/bin/`** — Thin binary entry points: `nh.rs` and `nighthawk_daemon.rs`.
- **`shells/`** — Shell plugins (zsh, bash, fish, PowerShell). NOT Rust — each is ~50 lines in the shell's native language.
- **`tools/fig-converter/`** — Node.js script that converts withfig/autocomplete TypeScript specs to nighthawk JSON format. One-time conversion tool, not part of the Rust build.

## Key daemon modules

- `src/daemon/server.rs` — tokio IPC listener via `interprocess` crate. Accepts connections, reads newline-delimited JSON, dispatches to PredictionEngine. Handles SIGTERM/SIGINT for graceful shutdown, cleans up socket + PID file on exit.
- `src/daemon/engine/mod.rs` — `PredictionEngine` orchestrates tiers in order. Returns first tier's results that produce suggestions.
- `src/daemon/engine/tier.rs` — `PredictionTier` trait. The primary extension point.
- `src/daemon/engine/history.rs` — Tier 0 implementation. Prefix-matches against shell history.
- `src/daemon/engine/specs.rs` — Tier 1 implementation. Looks up CLI specs for subcommands/options.
- `src/daemon/engine/llm.rs` — Tier 2 implementation (feature-gated: `local-llm`). Calls OpenAI-compatible `/v1/chat/completions` endpoint for LLM-powered suggestions.
- `src/daemon/specs/mod.rs` — `SpecProvider` trait, `SpecRegistry` (chains providers with cache), `CliSpec` types.
- `src/daemon/specs/fig.rs` — Loads pre-converted withfig/autocomplete JSON specs.
- `src/daemon/specs/helpparse.rs` — Parses `--help` output into `CliSpec`.
- `src/daemon/history/mod.rs` — `ShellHistory` trait.
- `src/daemon/history/file.rs` — Reads shell history files (zsh, bash, fish, PowerShell).
- `src/daemon/config.rs` — TOML config from `~/.config/nighthawk/config.toml`.

## Key CLI modules

- `src/cli/mod.rs` — Clap-based CLI entry point. Subcommands: `start`, `stop`, `status`, `setup`, `complete`.
- `src/cli/daemon_ctl.rs` — Daemon lifecycle: spawn detached process, PID file management, socket health checks, SIGTERM/SIGKILL stop.
- `src/cli/setup.rs` — `nh setup <shell>`: installs embedded plugin + specs to `~/.config/nighthawk/`, appends source line to shell rc file (idempotent).
- `src/cli/paths.rs` — Path helpers: `config_dir()`, `pid_file()`, `log_file()`, `specs_dir()`.

## Daemon management

- **PID file:** `~/.config/nighthawk/nighthawk.pid` — written by `nh start`, cleaned up on `nh stop` and daemon graceful shutdown.
- **Log file:** `~/.config/nighthawk/daemon.log` — daemon stdout/stderr redirected here by `nh start`.
- **Specs location:** `~/.config/nighthawk/specs/` (after `nh setup`) or `NIGHTHAWK_SPECS_DIR` env var override.
- **Plugin location:** `~/.config/nighthawk/nighthawk.zsh` or `nighthawk.ps1` (after `nh setup`).
- **Auto-start:** Shell plugins check if socket/pipe exists, try `nh start` once if missing.
- **Binary discovery:** `nh start` finds `nighthawk-daemon` next to the `nh` binary, falls back to PATH.

## Key traits

```rust
// src/daemon/engine/tier.rs — implement this to add a new prediction tier
#[async_trait]
pub trait PredictionTier: Send + Sync {
    fn name(&self) -> &str;
    fn budget_ms(&self) -> u32;
    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion>;
}

// src/daemon/specs/mod.rs — implement this to add a new spec source
pub trait SpecProvider: Send + Sync {
    fn get_spec(&self, command: &str) -> Option<CliSpec>;
    fn known_commands(&self) -> Vec<String>;
}

// src/daemon/history/mod.rs — implement this to add a new history backend
pub trait ShellHistory: Send + Sync {
    fn load(&mut self) -> Result<()>;
    fn search_prefix(&self, prefix: &str, limit: usize) -> Vec<HistoryEntry>;
}
```

## IPC protocol

- **Transport:** Unix socket (Linux/macOS) or named pipe (Windows) via `interprocess` crate
- **Format:** Newline-delimited JSON. One JSON object per line, terminated by `\n`.
- **Socket path:** `/tmp/nighthawk-$UID.sock` (Unix) or `\\.\pipe\nighthawk` (Windows)
- **Flow:** Plugin sends `CompletionRequest\n` → daemon responds with `CompletionResponse\n`
- **All types** defined in `src/proto/mod.rs`

## Conventions

**Error handling:** `thiserror` for error types. Never panic in the daemon. Failing tiers return empty vec, never crash the daemon. `anyhow` only in CLI entry points.

**Performance budgets:** Tier 0/1 MUST respond under 1ms. Full IPC round-trip MUST be under 5ms for Tier 0/1. Specs are lazy-loaded on first use, not at startup.

**Testing:** Unit tests in each module (`#[cfg(test)] mod tests`). Integration tests in `tests/` for IPC round-trips.

**Dependencies:** Minimize. Every new dependency must justify itself. Prefer std when it's close enough.

**Commits:** Follow [Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`. Use `Closes #N` / `Fixes #N` to auto-close GitHub issues.

**Pre-commit hook:** `.githooks/pre-commit` auto-runs `cargo fmt`. Activate with `git config core.hooksPath .githooks`.

## Recipes

### Adding a new shell plugin
1. Create `shells/nighthawk.<ext>`
2. Hook into the shell's input system (ZLE widget / readline bind / PSReadLine / fish bind)
3. On buffer change: send `CompletionRequest` JSON to socket, read `CompletionResponse`
4. Render first suggestion as ghost text: `ESC[s` save cursor → `ESC[90m` gray → print text → `ESC[0m` reset → `ESC[u` restore
5. Handle Tab (accept), Escape (dismiss)
6. Add shell variant to `Shell` enum in `src/proto/mod.rs`
7. Add history file path in `src/daemon/history/file.rs`
8. Add `nh setup <shell>` command in CLI

### Adding a new spec source
1. Create `src/daemon/specs/newsource.rs`, implement `SpecProvider` trait
2. Register in `SpecRegistry::new()` call in `src/daemon/mod.rs`
3. Providers are queried in order — first match wins

### Adding a new prediction tier
1. Create `src/daemon/engine/newtier.rs`, implement `PredictionTier` trait
2. Set `budget_ms()` appropriately
3. Add to tier list in `PredictionEngine::new()` call in `src/daemon/mod.rs`
4. Tiers run in order — fast tiers first
5. Return empty vec on errors, never panic

## What NOT to do

- **Never call LLMs from shell plugins** — all prediction goes through the daemon over IPC
- **Never render ghost text from the daemon** — that's the plugin's job, daemon just returns suggestions
- **Never load all specs at startup** — lazy-load and cache on first use
- **Never use platform-specific IPC directly** — use `interprocess` crate abstractions
- **Never expose HTTP/REST** — IPC only, the daemon is not a web server. (Outbound HTTP for LLM tiers is OK behind a feature flag.)
- **Never block the IPC server** — async all the way, slow tiers must not starve fast ones

## Design decisions

- **Full-token replacement, not append.** User types "ccla" → suggestion replaces with "claude", not "cclaude". `Suggestion` has `replace_start`/`replace_end` fields for this.
- **Daemon is the brain, plugins are dumb renderers.** Plugins know nothing about specs, history, or models.
- **ANSI ESC[90m works everywhere.** No terminal-specific rendering code. Ghost text is gray text + cursor save/restore.
- **Zero config works.** Everything functional with no config file, no API key, no login.
- **Cloud is always optional, always BYOK.** Never require a cloud account.
