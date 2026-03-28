# nighthawk

Open-source, local-first, cross-platform AI terminal autocomplete. The spiritual successor to [Fig](https://github.com/withfig/autocomplete).

<!-- TODO: Demo GIF here — 5-second loop showing ghost text in action -->

## What is this?

Type a command, see gray ghost text with the completion. Press Tab to accept. No login, no telemetry, no cloud required. Works in any terminal, any shell.

## Features

- **Inline ghost text** via ANSI escapes — works in any terminal emulator
- **500+ CLI specs** from the [withfig/autocomplete](https://github.com/withfig/autocomplete) community repo
- **Auto-parse `--help`** for any CLI without a spec
- **History-based predictions** — your most-used commands surface first
- **Full-token replacement** — typo-aware (`ccla` → `claude`, not `cclaude`)
- **Zero config** — works immediately with no API key, no login, no account
- **Cross-platform** — macOS, Linux, Windows
- **Multi-shell** — zsh, bash, fish, PowerShell
- **Local LLM support** *(coming soon)* — AI completions that never leave your machine
- **BYOK cloud** *(coming soon)* — bring your own API key for OpenAI, Anthropic, etc.

## Architecture

Lightweight Rust daemon + thin shell plugins (~50 lines each). The daemon runs a tiered prediction cascade:

| Tier | Latency | Source |
|------|---------|--------|
| 0 | <1ms | Shell history prefix matching |
| 1 | <1ms | Static CLI specs (withfig/autocomplete + --help parser) |
| 2 | ~50ms | Local LLM (future) |
| 3 | ~500ms | Cloud API, BYOK (future) |

## Status

**Early development.** Building in public.

| Shell | Status |
|-------|--------|
| zsh | In progress |
| bash | Planned |
| fish | Planned |
| PowerShell | Planned |
| nushell | Planned |

| Platform | Status |
|----------|--------|
| macOS | In progress |
| Linux | In progress |
| Windows | Planned |

## License

MIT
