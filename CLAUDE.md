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
│  ├─ Tier 2: Local LLM    ~50ms  │  (future)
│  └─ Tier 3: Cloud API   ~500ms  │  (future, BYOK)
│                                  │
│  Spec sources:                   │
│  ├─ withfig/autocomplete (500+)  │
│  ├─ --help auto-parser           │
│  └─ community specs              │
└──────────────────────────────────┘
```

## Crate map

- **`crates/nighthawk-proto/`** — IPC message types. `CompletionRequest`, `CompletionResponse`, `Suggestion`, `Shell`, `SuggestionSource`. Depends only on serde. Any crate that speaks the protocol depends on this.
- **`crates/nighthawk-daemon/`** — Background daemon. All prediction logic, spec loading, history indexing, IPC server. This is where 90% of the logic lives.
- **`crates/nighthawk-cli/`** — User-facing CLI (`nh start`, `nh setup zsh`, `nh complete "git ch"`). Depends on proto only.
- **`shells/`** — Shell plugins (zsh, bash, fish, PowerShell). NOT Rust — each is ~50 lines in the shell's native language.

## Key daemon modules

- `server.rs` — tokio IPC listener via `interprocess` crate. Accepts connections, reads newline-delimited JSON, dispatches to PredictionEngine.
- `engine/mod.rs` — `PredictionEngine` orchestrates tiers in order. Returns first tier's results that produce suggestions.
- `engine/tier.rs` — `PredictionTier` trait. The primary extension point.
- `engine/history.rs` — Tier 0 implementation. Prefix-matches against shell history.
- `engine/specs.rs` — Tier 1 implementation. Looks up CLI specs for subcommands/options.
- `specs/mod.rs` — `SpecProvider` trait, `SpecRegistry` (chains providers with cache), `CliSpec` types.
- `specs/fig.rs` — Loads pre-converted withfig/autocomplete JSON specs.
- `specs/helpparse.rs` — Parses `--help` output into `CliSpec`.
- `history/mod.rs` — `ShellHistory` trait.
- `history/file.rs` — Reads shell history files (zsh, bash, fish, PowerShell).
- `config.rs` — TOML config from `~/.config/nighthawk/config.toml`.

## Key traits

```rust
// engine/tier.rs — implement this to add a new prediction tier
#[async_trait]
pub trait PredictionTier: Send + Sync {
    fn name(&self) -> &str;
    fn budget_ms(&self) -> u32;
    async fn predict(&self, req: &CompletionRequest) -> Vec<Suggestion>;
}

// specs/mod.rs — implement this to add a new spec source
pub trait SpecProvider: Send + Sync {
    fn get_spec(&self, command: &str) -> Option<CliSpec>;
    fn known_commands(&self) -> Vec<String>;
}

// history/mod.rs — implement this to add a new history backend
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
- **All types** defined in `crates/nighthawk-proto/src/lib.rs`

## Conventions

**Error handling:** `thiserror` for error types. Never panic in the daemon. Failing tiers return empty vec, never crash the daemon. `anyhow` only in CLI entry points.

**Performance budgets:** Tier 0/1 MUST respond under 1ms. Full IPC round-trip MUST be under 5ms for Tier 0/1. Specs are lazy-loaded on first use, not at startup.

**Testing:** Unit tests in each module (`#[cfg(test)] mod tests`). Integration tests in `tests/` for IPC round-trips.

**Dependencies:** Minimize. Every new dependency must justify itself. Prefer std when it's close enough.

## Recipes

### Adding a new shell plugin
1. Create `shells/nighthawk.<ext>`
2. Hook into the shell's input system (ZLE widget / readline bind / PSReadLine / fish bind)
3. On buffer change: send `CompletionRequest` JSON to socket, read `CompletionResponse`
4. Render first suggestion as ghost text: `ESC[s` save cursor → `ESC[90m` gray → print text → `ESC[0m` reset → `ESC[u` restore
5. Handle Tab (accept), Escape (dismiss)
6. Add shell variant to `Shell` enum in `nighthawk-proto/src/lib.rs`
7. Add history file path in `history/file.rs`
8. Add `nh setup <shell>` command in CLI

### Adding a new spec source
1. Create `specs/newsource.rs`, implement `SpecProvider` trait
2. Register in `SpecRegistry::new()` call in `main.rs`
3. Providers are queried in order — first match wins

### Adding a new prediction tier
1. Create `engine/newtier.rs`, implement `PredictionTier` trait
2. Set `budget_ms()` appropriately
3. Add to tier list in `PredictionEngine::new()` call in `main.rs`
4. Tiers run in order — fast tiers first
5. Return empty vec on errors, never panic

## What NOT to do

- **Never call LLMs from shell plugins** — all prediction goes through the daemon over IPC
- **Never render ghost text from the daemon** — that's the plugin's job, daemon just returns suggestions
- **Never load all specs at startup** — lazy-load and cache on first use
- **Never use platform-specific IPC directly** — use `interprocess` crate abstractions
- **Never add HTTP/REST** — IPC only, the daemon is not a web server
- **Never block the IPC server** — async all the way, slow tiers must not starve fast ones

## Design decisions

- **Full-token replacement, not append.** User types "ccla" → suggestion replaces with "claude", not "cclaude". `Suggestion` has `replace_start`/`replace_end` fields for this.
- **Daemon is the brain, plugins are dumb renderers.** Plugins know nothing about specs, history, or models.
- **ANSI ESC[90m works everywhere.** No terminal-specific rendering code. Ghost text is gray text + cursor save/restore.
- **Zero config works.** Everything functional with no config file, no API key, no login.
- **Cloud is always optional, always BYOK.** Never require a cloud account.
