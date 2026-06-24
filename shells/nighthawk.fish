#!/usr/bin/env fish
# nighthawk fish plugin — inline ghost text autocomplete
#
# Install: fish auto-sources files in ~/.config/fish/conf.d/ — `nh setup fish` drops this there.
# Requires: socat, jq
#
# Architecture:
#   Sibling of the zsh/bash/PowerShell plugins. The Rust daemon is the brain; this plugin is a
#   thin renderer that sends a CompletionRequest over a Unix socket and draws the reply as ghost
#   text. fish has a clean buffer API (`commandline -b` / `commandline --cursor`) and `bind`
#   semantics, but — like bash/PowerShell — NO public API to inject into its native gray
#   autosuggestion, so ghost text will be ANSI direct-paint (decided in a later session).
#
# This file is the HELPER LAYER (the fish analogue of the bash plugin's "Session 1"): the pure,
# side-effect-free helpers (config, logging, control-char guard, UTF-8 offset conversion, jq
# request build, response parse, prefix-vs-hint decision) plus the pipeline that composes them.
# It loads but is otherwise INERT — no key bindings, no rendering, no IPC dispatch. Later sessions
# add: H1 native-autosuggestion coexistence, H2 rendering + buffer-change detection, H3 async IPC
# + debounce timer, H4 key bindings. (H1–H4 are the fish live-layer sessions, split finer than
# bash's S2 render+bind / S3 async — fish owns the native-autosuggestion-coexistence question as
# its own H1.) The helpers are factored so those sessions compose them without re-deriving any of
# this logic.
#
# CROSS-SHELL CONTRACTS preserved here (shared with zsh/bash/PowerShell, do not drift):
#   1. The daemon speaks UTF-8 BYTE offsets (replace_start/replace_end + the request cursor);
#      fish `commandline` is CODE-POINT domain, so we convert at the seam.
#   2. Suggestions carrying a control char are REJECTED (fail-closed), never stripped — an
#      embedded newline auto-submits on accept (single-keystroke RCE), an embedded ESC hijacks
#      the terminal during render.
#   3. Full-token replacement: a Suggestion carries replace_start/replace_end, not just a suffix.
#   4. The request's "shell" field is "fish" so the daemon routes fish history / detection.

# --- Socket path (env wins) ---
set -q NIGHTHAWK_SOCKET; or set -gx NIGHTHAWK_SOCKET "/tmp/nighthawk-"(id -u)".sock"

# --- Configuration defaults ---
# Mirrors the sibling plugins' [plugin] keys + env precedence (env > file > default). The arrow
# default is ASCII "->" (matching bash/PowerShell; zsh keeps the Unicode "→"). tab_accept is the
# bash-style opt-in: fish Tab drives completion/the pager, so binding it to accept is off by
# default — Right-arrow + Ctrl-F will always be the accept keys (wired in the H4 session).
set -g _nh_hint_arrow "->"
set -g _nh_debounce_ms 200
set -g _nh_debug 0
set -g _nh_tab_accept 0
set -g _nh_log_path (test -n "$XDG_CONFIG_HOME"; and echo "$XDG_CONFIG_HOME"; or echo "$HOME/.config")"/nighthawk/plugin.log"

# Minimal hand-rolled TOML reader: walk lines, track the current [section], pull the four keys we
# care about from [plugin]. No real parser, to stay dep-free. fish has none of the bash hazards
# here (no BASH_REMATCH clobber, no subshell-variable-loss, no octal traps), so this is short.
# `--groups-only` returns just the capture; an absent/EMPTY capture yields count 0, so an
# explicitly-empty value (e.g. hint_arrow = "") falls back to the default — an acceptable edge.
function _nh_load_config
    set -l cfgbase (test -n "$XDG_CONFIG_HOME"; and echo "$XDG_CONFIG_HOME"; or echo "$HOME/.config")
    set -l config_file "$cfgbase/nighthawk/config.toml"
    test -f "$config_file"; or return 0
    set -l in_plugin 0
    while read -l line
        set -l m (string match -r --groups-only '^\s*\[([^]]+)\]\s*$' -- $line)
        if test (count $m) -gt 0
            test "$m[1]" = plugin; and set in_plugin 1; or set in_plugin 0
            continue
        end
        test $in_plugin -eq 1; or continue
        set m (string match -r --groups-only '^\s*hint_arrow\s*=\s*"([^"]*)"' -- $line)
        if test (count $m) -gt 0
            set _nh_hint_arrow $m[1]
            continue
        end
        set m (string match -r --groups-only '^\s*debounce_ms\s*=\s*([0-9]+)' -- $line)
        if test (count $m) -gt 0
            set _nh_debounce_ms $m[1]
            continue
        end
        set m (string match -r --groups-only '^\s*debug\s*=\s*(true|false)' -- $line)
        if test (count $m) -gt 0
            test "$m[1]" = true; and set _nh_debug 1; or set _nh_debug 0
            continue
        end
        set m (string match -r --groups-only '^\s*tab_accept\s*=\s*(true|false)' -- $line)
        if test (count $m) -gt 0
            test "$m[1]" = true; and set _nh_tab_accept 1; or set _nh_tab_accept 0
        end
    end < "$config_file"
end
_nh_load_config

# --- Env overrides (env > file > default) ---
test -n "$NIGHTHAWK_HINT_ARROW"; and set _nh_hint_arrow "$NIGHTHAWK_HINT_ARROW"
test -n "$NIGHTHAWK_DEBOUNCE_MS"; and set _nh_debounce_ms "$NIGHTHAWK_DEBOUNCE_MS"
if test -n "$NIGHTHAWK_DEBUG"
    test "$NIGHTHAWK_DEBUG" = 1; and set _nh_debug 1; or set _nh_debug 0
end
if test -n "$NIGHTHAWK_TAB_ACCEPT"
    test "$NIGHTHAWK_TAB_ACCEPT" = 1; and set _nh_tab_accept 1; or set _nh_tab_accept 0
end

# Validate debounce before arithmetic: the config regex only accepts digits, but the env override
# is unguarded — a stray NIGHTHAWK_DEBOUNCE_MS=foo would otherwise make `math` error to an empty
# string and (in the H3 timer) `sleep ""` = a socat-fork-per-keystroke storm. Reset to default on
# non-digit, then normalize via `math` (fish parses leading zeros as decimal, no octal surprise).
string match -rq '^[0-9]+$' -- "$_nh_debounce_ms"; or set _nh_debounce_ms 200
set _nh_debounce_ms (math -s0 "$_nh_debounce_ms")

# Integer-ms -> fractional-seconds for the future debounce `sleep`. LOCALE-PROOF: builds the string
# from integer `math -s0` (floor div + modulo) spliced around a LITERAL ".", never a float — fish's
# `math`/`printf %f` would emit "0,200" under a comma-decimal locale and crash `sleep`. Floors to a
# 10ms minimum (ms=0 => `sleep 0` = NO debounce). Kept pure so the harness asserts the rows.
function _nh_ms_to_sec
    set -l ms $argv[1]
    string match -rq '^[0-9]+$' -- "$ms"; or set ms 200
    set ms (math -s0 "$ms")
    test $ms -lt 10; and set ms 10
    printf '%d.%03d' (math -s0 "$ms / 1000") (math -s0 "$ms % 1000")
end
set -g _nh_debounce_sec (_nh_ms_to_sec $_nh_debounce_ms)

# --- Diagnostic logging (no-op unless debug=1) ---
# Millisecond timestamps via GNU date's %N (Linux/WSL); a non-GNU date leaves "%3N" literal —
# harmless, never aborts.
function _nh_log
    test "$_nh_debug" = 1; or return 0
    printf '%s %s\n' (date '+%H:%M:%S.%3N' 2>/dev/null) "$argv[1]" >>"$_nh_log_path" 2>/dev/null
end

# --- Control-char guard (the security backstop) ---
# True iff $argv[1] holds a char that could hijack the terminal on paint, auto-submit on accept, or
# spoof the shown command (contract #2). Single fail-closed gate for daemon suggestions AND the
# config/env arrow. PCRE2 `\x{}` are CODE-POINT ranges (locale-independent — no `LC_ALL=C` the bash
# sibling needs); legit multibyte text (café, 中, 😀, →) sits outside them all and passes:
#   \x01-\x1f C0 (newline = auto-submit RCE, ESC) · \x7f DEL · \x80-\x9f C1 (0x9b = 8-bit CSI ≈ ESC[)
#   \x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}  bidi + zero-width: "Trojan Source"
#       (CVE-2021-42574) reorders/hides glyphs so the displayed command differs from the bytes run
#   \x{f600}-\x{f6ff}  fish round-trips an undecodable input byte B as code point 0xF600+B, so a raw
#       0x9b arrives as U+F69B (not U+009B) and would re-emit the raw CSI byte on output — caught here
# fish truncates a literal NUL, so the floor is 0x01; callers treat truncation as fail-closed. A
# custom arrow set to a zero-width / bidi / PUA glyph falls back to default — none are legit in a command.
function _nh_has_ctrl_char
    string match -rq '[\x01-\x1f\x7f-\x9f\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{f600}-\x{f6ff}\x{feff}]' -- "$argv[1]"
end

# The hint arrow comes from config/env (trusted less than code), yet it rides the SAME display
# field as the control-char-guarded daemon text — an unfiltered ESC here would reach the H2 renderer
# and hijack the terminal. Sanitize once, now that the guard exists, falling back to the default.
# (Deferred to here rather than at the config/env assignment because _nh_has_ctrl_char is defined
# below them.)
_nh_has_ctrl_char "$_nh_hint_arrow"; and set _nh_hint_arrow "->"

# --- UTF-8 byte offset <-> code-point index conversion ---
# The daemon speaks UTF-8 BYTE offsets; fish `string sub`/`commandline` index by CODE POINT. These
# bridge the two. Per-char byte width comes from the char's CODE POINT (`printf '%d' "'$ch"`, a
# POSIX printf feature, builtin = no fork) computed arithmetically — fish exposes no byte-length
# primitive (`string length` counts code points; there is no `--bytes`). Both fail CLOSED so a
# malformed offset can never corrupt the buffer. The common all-ASCII buffer is a fast identity
# path (no walk). The walk unit is one code point (`string split ''`), matching the daemon's
# code-point/byte granularity (NOT grapheme — a combining mark is its own offset, by design).

# Byte width (1-4) of a single code point from its value. Fail-safe to 1 on an empty/unreadable ch.
function _nh_cp_width
    set -l ch $argv[1]
    test -n "$ch"; or begin
        echo 1
        return
    end
    set -l cp (printf '%d' "'$ch" 2>/dev/null)
    test -n "$cp"; or begin
        echo 1
        return
    end
    if test $cp -lt 128
        echo 1
    else if test $cp -lt 2048
        echo 2
    else if test $cp -lt 65536
        echo 3
    else
        echo 4
    end
end

# Byte offset -> code-point index (count of leading code points). Fail-closed -1 for a negative
# offset, one past the end, or one landing INSIDE a multibyte sequence (detected by overshoot).
function _nh_byte_to_char
    set -l s $argv[1]
    set -l boff $argv[2]
    # Guard the offset arg before any test/math: this is a public primitive H3/H4 will call from
    # new sites, and an empty/non-numeric offset would otherwise spew `Invalid number:` to stderr
    # (the result stays fail-closed, but the noise is a bug). Non-numeric -> -1.
    if not string match -rq '^-?[0-9]+$' -- "$boff"
        echo -1
        return
    end
    if test $boff -lt 0
        echo -1
        return
    end
    if test $boff -eq 0
        echo 0
        return
    end
    # ASCII fast-path: byte == char.
    if not string match -rq '[^\x00-\x7f]' -- "$s"
        set -l n (string length -- "$s")
        test $boff -le $n; and echo $boff; or echo -1
        return
    end
    set -l acc 0
    set -l i 0
    for ch in (string split '' -- "$s")
        set i (math $i + 1)
        set acc (math $acc + (_nh_cp_width $ch))
        if test $acc -eq $boff   # exact code-point boundary
            echo $i
            return
        end
        if test $acc -gt $boff   # offset split a multibyte char
            echo -1
            return
        end
    end
    echo -1   # offset past the last byte
end

# Code-point index -> byte offset. Clamps an over-long index to the length; returns 0 for <= 0.
function _nh_char_to_byte
    set -l s $argv[1]
    set -l cidx $argv[2]
    # Guard the index arg (same rationale as _nh_byte_to_char). Non-numeric / <= 0 -> byte 0.
    if not string match -rq '^-?[0-9]+$' -- "$cidx"
        echo 0
        return
    end
    if test $cidx -le 0
        echo 0
        return
    end
    set -l n (string length -- "$s")
    test $cidx -gt $n; and set cidx $n
    # ASCII fast-path: char == byte.
    if not string match -rq '[^\x00-\x7f]' -- "$s"
        echo $cidx
        return
    end
    set -l acc 0
    for ch in (string split '' -- (string sub -l $cidx -- "$s"))
        set acc (math $acc + (_nh_cp_width $ch))
    end
    echo $acc
end

# Byte length of a whole string == the byte offset of its EOL. Its consumer is REQUEST-BUILDING
# (the daemon wants the cursor as a byte offset). It is NOT the "cursor at EOL?" gate — fish's
# cursor (`commandline --cursor`) is code-point domain, so the live layer's EOL check stays in the
# code-point domain. Importing bash's "EOL == byte length" assumption would be a multibyte bug.
function _nh_eol_bytes
    _nh_char_to_byte "$argv[1]" (string length -- "$argv[1]")
end

# --- Request build (jq) ---
# Pure-ish string -> JSON. jq is already a dependency, so it does the OUTBOUND escaping too (--arg
# escapes \ " and control chars; multibyte passes through RAW so the daemon's byte offsets over
# `input` agree with ours). This deletes the hand-rolled escaper the siblings carry. Takes the
# cursor ALREADY converted to a byte offset (the char->byte conversion belongs at snapshot time in
# the H3 dispatch, not here). Emits "shell":"fish" so the daemon routes fish history / detection.
function _nh_build_request
    # Validate the cursor is a plain non-negative integer before it reaches `--argjson`, which
    # parses its value as RAW JSON. The contracted caller always passes a byte offset, but this
    # keeps a careless future caller from injecting JSON structure into the request. Reject -> no
    # request (the daemon seam stays fail-closed).
    string match -rq '^[0-9]+$' -- "$argv[2]"; or return 1
    jq -nc --arg input "$argv[1]" --argjson cursor "$argv[2]" --arg cwd "$argv[3]" \
        '{input:$input,cursor:$cursor,cwd:$cwd,shell:"fish"}'
end

# --- Response parse (jq) ---
# Emits a TAB-separated record for the first suggestion: replace_start, replace_end,
# diff_ops_present (0/1), then TEXT LAST. Text is last so a tab inside it (rejected downstream)
# can't break the framing — the caller splits with `string split -m 3` so field 4 keeps any tabs
# verbatim. On malformed JSON jq prints nothing (status != 0); the caller defaults its locals to
# empty FIRST, so an empty parse can't leave stale fields (the fish equivalent of the bash
# self-defaulting eval). Only suggestions[0] is used, matching the siblings. diff_ops is reduced to
# a PRESENCE flag (bash/PowerShell are hint-only — see the no-inline-diff decision). A FUTURE fish
# inline-diff renderer MUST add a control-char guard over the per-op `ch` bytes (as zsh does), or
# it reopens the newline/ESC injection vector that the text-only guard does not cover.
function _nh_parse_response
    printf '%s' "$argv[1]" | jq -rj '
        if (.suggestions | length) > 0 then
            ((.suggestions[0].replace_start // "" | tostring)) + "\t"
            + ((.suggestions[0].replace_end // "" | tostring)) + "\t"
            + (if (.suggestions[0].diff_ops // null) then "1" else "0" end) + "\t"
            + (.suggestions[0].text // "")
        else
            "\t\t0\t"
        end
    ' 2>/dev/null
end

# --- Prefix-vs-hint decision (pure) ---
# Echoes a tagged, display-ready payload for the H2 renderer to dispatch on:
#   ghost\t<suffix>     true prefix match — render <suffix> as ghost after the cursor
#   hint\t -> <text>    replacement / fuzzy — render as a hint
#   (empty)             nothing to show
# Split on the FIRST tab. The hint payload's LEADING SPACE is load-bearing — part of the rendered
# " -> <text>" prefix; emit it verbatim, never trim. fish follows the PowerShell hint-only model: a
# fuzzy match (diff present) always renders as a hint. <rstart> is the CODE-POINT replace_start
# (already byte->char converted). Self-guards rstart so a -1 from a failed conversion can't reach a
# `string sub`. CURSOR INVARIANT: derives typed_len = (len buffer) - rstart, i.e. assumes the
# cursor sits at end-of-line (the suggest path only fires at EOL). The H3 caller MUST uphold that;
# mid-line suggestions would need an explicit cursor argument like the zsh/PS siblings.
function _nh_decide_render
    set -l buffer $argv[1]
    set -l text $argv[2]
    set -l rstart $argv[3]
    set -l diff $argv[4]
    test -n "$text"; or return 0
    string match -rq '^[0-9]+$' -- "$rstart"; or return 0
    set -l blen (string length -- "$buffer")
    test $rstart -gt $blen; and return 0
    if test "$diff" = 1
        printf 'hint\t %s %s' "$_nh_hint_arrow" "$text"
        return 0
    end
    set -l typed_len (math $blen - $rstart)
    set -l tlen (string length -- "$text")
    test $typed_len -ge 0 -a $typed_len -lt $tlen; or return 0
    set -l typed_part (string sub -s (math $rstart + 1) -l $typed_len -- "$buffer")
    set -l text_prefix (string sub -l $typed_len -- "$text")
    if test "$text_prefix" = "$typed_part"
        printf 'ghost\t%s' (string sub -s (math $typed_len + 1) -- "$text")   # true prefix: suffix as ghost
    else
        printf 'hint\t %s %s' "$_nh_hint_arrow" "$text"                        # replacement: hint
    end
end

# --- Response pipeline (pure) ---
# Composes parse -> control-char reject -> byte->char convert -> range-validate -> decide against a
# buffer SNAPSHOT and a raw daemon reply. Output is the 5-field record
#   <kind>\t<display>\t<bstart>\t<bend>\t<text>
# (empty when there is nothing to show): the 2-field display tag from _nh_decide_render plus the
# daemon's BYTE range + full replacement text for the accept path. The H3 worker splits it and
# stashes bstart/bend/text for accept. bstart/bend are the daemon's own BYTE offsets (accept
# splices in the byte domain); the byte->char conversion here is purely the fail-closed
# code-point-boundary guard. The capture uses `string collect -N` (NOT plain collect, which trims a
# trailing newline — that would silently turn a newline-terminated RCE payload from a fail-closed
# REJECT into a strip-and-accept).
function _nh_compute_suggestion
    set -l buffer $argv[1]
    set -l response $argv[2]
    # Default FIRST so an empty/failed parse can't leave stale fields.
    set -l rstart ""
    set -l rend ""
    set -l diff 0
    set -l text ""
    set -l parsed (_nh_parse_response "$response" | string collect -N)
    test -n "$parsed"; or return 0
    set -l fields (string split -m 3 \t -- $parsed)
    test (count $fields) -ge 4; or return 0
    set rstart $fields[1]
    set rend $fields[2]
    set diff $fields[3]
    set text $fields[4]
    test -n "$text"; or return 0
    # Fail-closed: drop any suggestion carrying a control char before it can render or be accepted.
    if _nh_has_ctrl_char "$text"
        _nh_log "rejected: control char in suggestion"
        return 0
    end
    # Reject a non-integer range (e.g. "null"/"" from a malformed reply) before arithmetic.
    string match -rq '^[0-9]+$' -- "$rstart"; and string match -rq '^[0-9]+$' -- "$rend"; or return 0
    # Protocol byte offsets -> code-point indices against the snapshot. Fail closed if out of range
    # or mid-codepoint.
    set -l cstart (_nh_byte_to_char "$buffer" "$rstart")
    set -l cend (_nh_byte_to_char "$buffer" "$rend")
    if test $cstart -lt 0 -o $cend -lt 0 -o $cend -lt $cstart
        _nh_log "rejected: replace range not on a code-point boundary"
        return 0
    end
    set -l tag (_nh_decide_render "$buffer" "$text" "$cstart" "$diff")
    test -n "$tag"; or return 0
    # Append the ACCEPT payload as three more TAB fields: <kind>\t<display>\t<bstart>\t<bend>\t<text>.
    # bstart/bend are the daemon's BYTE offsets (what accept wants), not the char offsets above.
    printf '%s\t%s\t%s\t%s' "$tag" "$rstart" "$rend" "$text"
end

# --- Dependency check ---
# AFTER the pure helpers (mirrors the bash ordering) so the unit harness can source this file and
# exercise the helpers structurally even on a box without the deps — a "helper not defined" test
# failure then means "renamed", not "deps missing". A sourced-file `return` stops sourcing here but
# leaves every function above defined.
if not command -q socat
    echo "nighthawk: socat not found, install with: apt install socat" >&2
    return 1
end
if not command -q jq
    echo "nighthawk: jq not found, install with: apt install jq" >&2
    return 1
end

# ======================================================================================
# LIVE LAYER — interactive only. Everything below runs solely in an interactive session; a
# non-interactive load (the unit harness, a plain `source`) stops at the guard with every helper
# above still defined and nothing mutated. Built up one session each:
#   H1 (below): suppress fish's native autosuggestion so our ghost text owns the cells.
#   H2 (todo):  ghost rendering + buffer-change detection (fish repaints after each binding).
#   H3 (todo):  async / non-blocking IPC + debounce timer (fish is single-threaded: no `zle -F`
#               fd-callbacks, no RunspacePool) — wires _nh_request / _nh_ensure_daemon + dispatch.
#   H4 (todo):  key bindings + live loop: accept (Right/Ctrl-F; Tab opt-in via _nh_tab_accept),
#               Escape dismiss, cursor motions, Enter-clear, per-keystroke insert+trigger.
# ======================================================================================
status is-interactive; or return 0

# --- H1: suppress fish's native autosuggestion (coexist-vs-suppress — issue #87's core question) ---
# fish's autosuggestion is native C++ that paints its own gray ghost in EXACTLY the cells the H2
# renderer will use, and fish exposes NO public hook to read or inject into it: the only accessor,
# `commandline --showing-suggestion`, is a read-only "is one showing?" predicate — no text, no
# injection point. So fish is the PowerShell/PSReadLine case (native predictor, no inject API), NOT
# the zsh/region_highlight case (a cooperative, additive API we could render through). We can only
# REPLACE it, never coexist — two gray ghosts would collide in the same cells with no way to dedupe.
# Suppress it outright: the fish analogue of the PS plugin's `Set-PSReadLineOption -PredictionSource
# None`. `set -g` (session global) shadows a user's `set -U fish_autosuggestion_enabled 1` on read
# WITHOUT destroying it, so their universal config survives a plugin uninstall. A side benefit:
# with native off, `--showing-suggestion` is always false, so H4's Right/Ctrl-F accept binding fully
# owns those keys instead of racing fish's `forward-char` / `forward-single-char` defaults.
#
# Placed AFTER the dependency check ON PURPOSE: if socat/jq are missing we already `return 1`ed
# above, leaving native autosuggestion intact — suppressing it when nighthawk cannot function would
# strand the user with NO suggestions at all. Tier 0 (history prefix) is a strict superset of fish's
# native history ghost, so once the daemon is up this is parity-plus; the only gap is the brief
# daemon-start window, which the plugin's auto-start closes. Unconditional (no opt-out knob) for
# parity with the PS sibling — re-enabling native alongside our ghost is a dual-paint footgun.
set -g fish_autosuggestion_enabled 0
