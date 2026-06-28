# nighthawk

Open-source, local-first, cross-platform AI terminal autocomplete. The spiritual successor to [Fig](https://github.com/withfig/autocomplete).

<!-- TODO: Demo GIF here — 5-second loop showing ghost text in action -->

## What is this?

Type a command, see gray ghost text with the completion. Press Tab to accept. No login, no telemetry, no cloud required. Works in any terminal, any shell.

## Features

- **Inline ghost text** via ANSI escapes — works in any terminal emulator
- **689+ CLI specs** from the [withfig/autocomplete](https://github.com/withfig/autocomplete) community repo
- **Auto-parse `--help`** for any CLI without a spec
- **History-based predictions** — your most-used commands surface first
- **Full-token replacement** — typo-aware (`ccla` → `claude`, not `cclaude`)
- **Zero config** — works immediately with no API key, no login, no account
- **Cross-platform** — macOS, Linux, Windows
- **Multi-shell** — zsh and PowerShell (5.1+, 7+)
- **Local LLM support** — AI completions via local Ollama / llama.cpp / vLLM, never leave your machine (opt-in via `--features local-llm`)
- **BYOK cloud** — bring your own API key for OpenAI, Anthropic, or Groq (opt-in via `--features cloud-llm`)

## Install

Requires the [Rust toolchain](https://rustup.rs) (`cargo`).

```sh
cargo install nighthawk
```

This installs two binaries to `~/.cargo/bin`: `nh` (CLI) and `nighthawk-daemon`.

**zsh runtime dependencies.** The zsh plugin shells out to `socat` (IPC) and `jq` (JSON parsing) — install them first or ghost text won't appear:

```sh
sudo apt install socat jq    # Debian/Ubuntu
brew install socat jq        # macOS
```

**Syntax-highlighting coexistence.** On **zsh 5.9+** nighthawk tags its `region_highlight` entries with a `memo` field so it removes only its own ghost-text highlights — it coexists cleanly with `zsh-syntax-highlighting` and similar plugins regardless of load order. On zsh 5.8 and older (e.g. Ubuntu 22.04, Debian 11) `memo` isn't supported; nighthawk falls back to positional removal, which can briefly disturb a co-resident highlighter's coloring. Ghost text still works everywhere.

**Optional AI tiers** are off by default (local-first, zero-config). Opt in at install time:

```sh
cargo install nighthawk --features local-llm   # Tier 2: local Ollama / llama.cpp / vLLM
cargo install nighthawk --features cloud-llm    # Tier 3: BYOK OpenAI / Anthropic / Groq
```

## Quickstart

```sh
nh setup         # interactive wizard: auto-detects your shell, then installs everything
exec zsh         # reload your shell
```

Already know your shell? Skip the prompts:

```sh
nh setup zsh     # installs the plugin + specs, adds a source line to ~/.zshrc (idempotent)
```

Start typing a command — gray ghost text shows the completion. **Tab** (or **→** at end of line) accepts, **Esc** dismisses. The daemon auto-starts on first use; manage it with `nh start` / `nh stop` / `nh status`.

> PowerShell: `nh setup powershell` instead, then restart your shell. (PowerShell has no `socat`/`jq` dependency.)

> bash: `nh setup bash` instead, then `exec bash`. Requires `socat` + `jq` (like zsh). **Accept keys in bash are → (right arrow) and Ctrl-F — not Tab.** Tab stays bound to native completion by default, because bash's `bind -x` (unlike zsh's `zle expand-or-complete` or PowerShell's `TabCompleteNext`) cannot fall back to native completion once it's rebound. To make **Tab** accept the suggestion instead, set `tab_accept = true` under `[plugin]` in `~/.config/nighthawk/config.toml` (or `NIGHTHAWK_TAB_ACCEPT=1`) — but note this **disables native Tab-completion** in bash whenever no suggestion is showing. zsh and PowerShell are unaffected: they bind Tab to accept *and* keep native completion.

## Architecture

Lightweight Rust daemon + thin shell plugins (~50 lines each). The daemon runs a tiered prediction cascade:

| Tier | Latency | Source |
|------|---------|--------|
| 0 | <1ms | Shell history prefix matching |
| 1 | <1ms | Static CLI specs (withfig/autocomplete + --help parser) |
| 2 | ~500ms | Local LLM (Ollama / llama.cpp / vLLM) |
| 3 | ~2s | Cloud API (OpenAI / Anthropic / Groq, BYOK) |

## Status

**Early development.** Building in public.

| Shell | Status |
|-------|--------|
| zsh | Supported |
| PowerShell (5.1+, 7+) | Supported |
| bash | Beta — accept on → / Ctrl-F (Tab opt-in, see Quickstart) |
| fish | Planned |
| nushell | Planned |

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Windows | Supported |

## License

MIT
