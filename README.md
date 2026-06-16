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

**Optional AI tiers** are off by default (local-first, zero-config). Opt in at install time:

```sh
cargo install nighthawk --features local-llm   # Tier 2: local Ollama / llama.cpp / vLLM
cargo install nighthawk --features cloud-llm    # Tier 3: BYOK OpenAI / Anthropic / Groq
```

## Quickstart

```sh
nh setup zsh     # installs the plugin + specs, adds a source line to ~/.zshrc (idempotent)
exec zsh         # reload your shell
```

Start typing a command — gray ghost text shows the completion. **Tab** (or **→** at end of line) accepts, **Esc** dismisses. The daemon auto-starts on first use; manage it with `nh start` / `nh stop` / `nh status`.

> PowerShell: `nh setup powershell` instead, then restart your shell. (PowerShell has no `socat`/`jq` dependency.)

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
| bash | Planned |
| fish | Planned |
| nushell | Planned |

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Windows | Supported |

## License

MIT
