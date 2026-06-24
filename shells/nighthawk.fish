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

# --- H2 render primitives (pure ANSI builders + the single tty sink) ---
# Defined HERE, above the dep check + interactive guard, so the unit harness exercises the pure
# builders structurally even on a depless / non-interactive load (same rationale as the helpers
# above). INERT: nothing CALLS them yet — H3 fires the worker that paints, H4 binds the keys that
# clear. Design proven by the H2 PTY redraw probe (fish 4.2.1): fish never repaints while IDLE (a
# worker-painted ghost survives the debounce window), never clears our out-of-band ghost on line-
# GROW (so WE clear it every keystroke — fish emits ESC[K only on shrink), and reprints the buffer
# via ABSOLUTE-CR repositioning (so its own redraw self-corrects and can't be corrupted by our paint
# as long as we save/restore the cursor). Ghost text is therefore raw ANSI to the tty: fish has no
# zsh-style script-facing region API, and `commandline --insert` would mutate the REAL buffer.

# ESC byte, computed once. `set -g` (NOT `set -l`) so the functions below capture it — a script-level
# `set -l` is invisible inside a `function` body in fish.
set -g _nh_esc (printf '\e')

# Clear sequence (PURE): save cursor -> erase to end of SCREEN -> restore. ESC[0J (not ESC[K) so a
# ghost that WRAPPED past the row is fully erased. CONTRACT: the caller must have the cursor at
# buffer-EOL before emitting this — we only ever suggest at EOL (as bash does), so ESC[0J erases only
# ghost cells, never real buffer text to the right of a mid-line cursor.
function _nh_clear_seq
    printf '%s[s%s[0J%s[u' $_nh_esc $_nh_esc $_nh_esc
end

# Paint sequence (PURE) for a display string: save cursor -> gray (ESC[90m) -> text -> reset ->
# restore. Restoring leaves the real caret at buffer-EOL, so the ghost is purely decorative. This is
# the LAST gate before bytes reach the terminal, so it RE-RUNS the control-char guard (defense in
# depth over _nh_compute_suggestion's upstream reject) and paints NOTHING on a dirty or empty display.
function _nh_paint_seq
    set -l display $argv[1]
    test -n "$display"; or return 0
    _nh_has_ctrl_char "$display"; and return 0
    printf '%s[s%s[90m%s%s[0m%s[u' $_nh_esc $_nh_esc "$display" $_nh_esc $_nh_esc
end

# Render sequence (PURE): bridge a _nh_compute_suggestion record to a paint sequence. The record is
# <kind>\t<display>\t<bstart>\t<bend>\t<text>; only <display> (field 2) is drawn — the gray text for
# BOTH kinds (ghost = the unseen suffix; hint = " -> text"). Empty / malformed record paints nothing.
function _nh_render_seq
    set -l record $argv[1]
    test -n "$record"; or return 0
    set -l fields (string split -m 4 \t -- $record)
    test (count $fields) -ge 2; or return 0
    _nh_paint_seq "$fields[2]"
end

# The ONE /dev/tty sink (thin, side-effecting). Both clear and paint route through here, so a future
# flock escape hatch (if interleaved writes ever corrupt the line under fast typing) has a SINGLE
# home — exactly as the bash sibling. Silent if there is no controlling tty.
function _nh_tty_write
    printf '%s' "$argv[1]" >/dev/tty 2>/dev/null
end

# Thin tty compositions (INERT until H3 paints / H4 clears). Kept tiny so the side-effecting surface
# stays obvious and auditable.
function _nh_clear_ghost
    _nh_tty_write (_nh_clear_seq)
    # Drop the accept stash too (the H3 cross-process accept payload): a cleared ghost must never stay
    # acceptable. Mirrors the bash sibling — defense-in-depth so H4's accept can't fire on a visually
    # cleared suggestion even if a generation check were ever to pass. Guarded so it no-ops on a
    # non-interactive source (empty run dir), keeping the unit harness inert. (Defined in the H2 block
    # but stash-aware now that H3 introduced the stash; the `set -g _nh_run_dir` below is read at CALL
    # time, never at definition, so the forward reference is fine.)
    test -n "$_nh_run_dir"; and rm -f "$_nh_run_dir/stash"
end
function _nh_paint_ghost
    _nh_tty_write (_nh_render_seq "$argv[1]")
end

# Input-change predicate (PURE) for H4's per-keystroke gate: true (status 0) when the buffer OR the
# cursor differs from the prior snapshot, so the daemon is re-queried only on a REAL change (a no-op
# keypress / repeated binding must not re-fire). Cursor is part of the key because a suggestion is
# position-dependent (it only fires at EOL). H4 owns the interactive snapshot (`commandline -b` /
# `--cursor`); this is just the testable decision kernel. Args: <old_buf> <old_cur> <new_buf> <new_cur>.
function _nh_input_changed
    test "$argv[1]" != "$argv[3]"; or test "$argv[2]" != "$argv[4]"
end

# --- H3 async core (state + cross-process generation + the background worker) ---
# fish is single-threaded with no `zle -F` fd-callback (zsh) and no RunspacePool (PowerShell), so async
# rendering is the bash model: a background WORKER paints the ghost straight to /dev/tty and round-trips
# the accept payload through a `stash` FILE. The H2 redraw probe proved the two facts this rests on —
# fish never repaints while IDLE (a worker-painted ghost survives the debounce window) and never clears
# our out-of-band ghost on its own (we clear it every keystroke). The foreground keystroke handler (H4)
# fire-and-forgets ONE worker; a monotonic generation counter mirrored to a `gen` file is the SOLE
# cross-process staleness token. Defined HERE (above the dep check + interactive guard) so the harness
# unit-tests the state primitives against a scaffolded run dir; nothing CALLS them until the interactive
# guard runs _nh_state_init (below) and H4 binds the keys that fire _nh_dispatch.
#
# State globals (mutated by the functions below; `set -g` so the forked worker inherits them):
#   _nh_gen            monotonic generation, the in-process authority. Bumped on every dispatched
#                      keystroke; mirrored to "$_nh_run_dir/gen" so a worker can detect it was superseded.
#   _nh_run_dir        per-load nonce'd dir holding `gen` + `stash` (set by _nh_state_init in the
#                      interactive guard; EMPTY on a non-interactive source => every helper below no-ops,
#                      which is what keeps the unit harness inert).
#   _nh_backoff_until  epoch-seconds gate; a missing socket arms a 5s backoff so dispatch can't hammer a
#                      dead daemon. (A present-but-hung daemon costs one off-keystroke worker eating
#                      socat -t3 — never a freeze — so it needs no cross-process marker.)
set -g _nh_gen 0
set -g _nh_run_dir ""
set -g _nh_backoff_until 0

# Captured at SOURCE time (where `status filename`/`status fish-path` resolve correctly): the absolute
# path of THIS plugin and the running fish binary. _nh_dispatch re-execs that binary to re-source this
# file in a detached worker (fish cannot background a function — see _nh_dispatch). `path resolve`
# makes the path absolute so the worker's `source` works regardless of its CWD. Recomputed harmlessly
# when the worker re-sources.
set -g _nh_plugin_file (path resolve (status filename))
set -g _nh_fish_bin (status fish-path)
# `status fish-path` exists on every fish >= 3.6 (target is 4.2.1), but fall back to a bare PATH
# lookup so a missing value can never make _nh_dispatch spawn a broken command on the keystroke path.
test -n "$_nh_fish_bin"; or set -g _nh_fish_bin fish

# Per-session run dir + cross-process generation. The per-load mktemp NONCE makes re-source teardown
# real: a fresh load picks a new path, so any in-flight worker from a prior load reads `cat gen` ->
# ENOENT and exits. fish's PID is `$fish_pid` (the bash `$$`); the worker, being a forked child, sees
# the PARENT'S $fish_pid, so the dir is always stamped with the interactive shell's PID here in the
# foreground. Non-matching globs in a `for` header iterate ZERO times in fish (no error), so the reap
# and GC loops are safe on first load.
function _nh_state_init
    set -l base /tmp
    test -n "$TMPDIR"; and set base "$TMPDIR"
    # Reap THIS shell's prior-load dirs (re-source: same PID, the new dir isn't created yet).
    for d in $base/nighthawk-plugin-$fish_pid-*
        test -d "$d"; and string match -q '*/nighthawk-plugin-*' -- "$d"; and rm -rf -- "$d"
    end
    # Opportunistic GC of crashed/HUP'd OTHER sessions whose PID is no longer alive.
    for d in $base/nighthawk-plugin-*
        test -d "$d"; or continue
        set -l pid (string match -r --groups-only -- '/nighthawk-plugin-([0-9]+)-' "$d")
        string match -rq '^[0-9]+$' -- "$pid"; or continue
        kill -0 "$pid" 2>/dev/null; and continue
        string match -q '*/nighthawk-plugin-*' -- "$d"; and rm -rf -- "$d"
    end
    # mktemp -d atomically creates a 0700 dir with an unpredictable suffix and FAILS on collision —
    # closing the predictable-name window a bare `mkdir $fish_pid-$rand` would open on a world-writable
    # $TMPDIR (another local user could pre-create the dir and read/tamper with gen/stash). The
    # $fish_pid stays in the template so the reap + dead-PID GC above can still parse the PID back out.
    set -g _nh_run_dir (mktemp -d "$base/nighthawk-plugin-$fish_pid-XXXXXXXX" 2>/dev/null)
    # `set` does not reliably propagate a failed command substitution's status in fish, so verify the
    # dir explicitly rather than trusting an `or` on the assignment.
    if test -z "$_nh_run_dir"; or not test -d "$_nh_run_dir"
        set -g _nh_run_dir ""
        return 1
    end
    set -g _nh_gen 0
    printf '%s' 0 >"$_nh_run_dir/gen"
end

# Remove our run dir. GUARDED against an empty/foreign path so a bare `rm -rf "$var"` can never run on
# an unset var. The crash/HUP/KILL backstop is the dead-PID GC in _nh_state_init on the next load.
function _nh_cleanup
    test -n "$_nh_run_dir"; and string match -q '*/nighthawk-plugin-*' -- "$_nh_run_dir"
    and rm -rf -- "$_nh_run_dir"
end

# Bump the generation: in-process counter + a fork-free write-through to the `gen` file (plain
# `printf >`, NOT temp+mv — the staleness guarantee is not write atomicity; see the bash sibling's
# torn-read note). The SINGLE gen mutator, so the var and the file can't skew. A no-op on an unset
# _nh_run_dir, which is what keeps it inert under the unit harness until a run dir is injected.
function _nh_bump_gen
    test -n "$_nh_run_dir"; or return 0
    set -g _nh_gen (math $_nh_gen + 1)
    printf '%s' $_nh_gen >"$_nh_run_dir/gen"
end

# Daemon auto-start (best-effort, detached). Backgrounded + disowned so it never blocks the keystroke
# and prints no job message; the caller's backoff prevents re-spawning every keystroke when `nh` is
# missing or the daemon won't come up.
function _nh_ensure_daemon
    if command -q nh
        nh start >/dev/null 2>&1 &
        disown 2>/dev/null
    end
end

# The blocking IPC round-trip, isolated so the transport (socat flags / timeout) has ONE home. Takes a
# built request JSON, returns the first response line. `head -n1` closes after one line so socat takes
# SIGPIPE and exits. Runs ONLY inside the background worker — never on the keystroke path.
function _nh_request
    printf '%s\n' "$argv[1]" | socat -t3 - "UNIX-CONNECT:$NIGHTHAWK_SOCKET" 2>/dev/null | head -n1
end

# Dispatch (FOREGROUND, non-blocking). Clear the prior ghost, bump the generation (a changed
# buffer/cursor makes any in-flight worker's suggestion stale), run the cheap foreground guards, then
# fire-and-forget ONE worker. Nothing here blocks the keystroke: the only fork in the steady state is
# the backgrounded worker itself (every `test`/`string`/`printf` is a fish builtin, and `date` is read
# ONLY when the backoff is armed — a fork the bash sibling needed $EPOCHSECONDS to avoid). H4 snapshots
# the live buffer/cursor and passes them in, so this stays testable and `commandline` lives only in H4.
# Args: <buffer> <cursor_chars>. cursor_chars is the CODE-POINT index from `commandline --cursor`; the
# EOL gate is therefore CHAR-domain (NOT byte like bash's READLINE_POINT) — we only suggest at EOL.
function _nh_dispatch
    set -l buffer $argv[1]
    set -l cursor $argv[2]
    _nh_clear_ghost
    _nh_bump_gen
    test -n "$_nh_run_dir"; or return 0
    set -l blen (string length -- "$buffer")
    test $blen -ge 2; or return 0
    test "$cursor" = "$blen"; or return 0   # cursor at EOL (code-point domain)
    # Backoff gate: only read the clock when the backoff is actually armed (avoids a per-keystroke
    # `date` fork in the common socket-up path; _nh_backoff_until stays 0 then).
    if test $_nh_backoff_until -gt 0
        set -l now (date +%s)
        test $now -lt $_nh_backoff_until; and return 0
    end
    if not test -S "$NIGHTHAWK_SOCKET"
        set -g _nh_backoff_until (math (date +%s) + 5)
        _nh_ensure_daemon
        return 0
    end
    # The daemon wants the cursor as a BYTE offset; at EOL that is the buffer's byte length.
    set -l blen_bytes (_nh_eol_bytes "$buffer")
    set -l gen0 $_nh_gen
    # fish cannot detach a FUNCTION with `&` — it runs the body SYNCHRONOUSLY in the current shell
    # (verified: `fn &`, `fn | cat &`, and `begin; fn; end | cat &` all block the parent for the full
    # worker runtime). Only an EXTERNAL process detaches. So re-exec the running fish binary, which
    # re-sources this plugin (~12ms, entirely OFF the keystroke thread) to reconstitute the helper
    # functions, then runs the worker. The buffer + args travel as POSITIONAL $argv (never spliced
    # into the -c string), so a buffer with spaces/quotes/$/; carries through with zero eval or
    # injection surface. The run dir is passed as an arg because the fresh process never ran the
    # interactive _nh_state_init, so ITS _nh_run_dir global is empty. NIGHTHAWK_SOCKET + the debounce
    # ride through the env / the re-source. Backgrounded + disowned so no job-completion message ever
    # corrupts the prompt line.
    #
    # `--no-config`: the worker re-source is a HOT path (one per keystroke), and a bare `fish -c` would
    # re-run the user's whole config.fish + conf.d on every spawn — a heavy config (conda/nvm/starship
    # init) would then tax every keystroke off-thread for tens-to-hundreds of ms. The worker needs NONE
    # of that: it sources THIS plugin explicitly (which reads config.toml on its own) and inherits PATH +
    # NIGHTHAWK_SOCKET + PWD from the parent env, so socat/jq resolve without config.fish. Skipping it
    # keeps the spawn ~1.8ms (vs ~3.3ms) here and immune to an arbitrarily heavy user config elsewhere.
    $_nh_fish_bin --no-config -c 'source $argv[1]; _nh_worker $argv[2] $argv[3] $argv[4] $argv[5]' \
        $_nh_plugin_file $gen0 "$buffer" $blen_bytes $_nh_run_dir &
    disown 2>/dev/null
end

# Worker (forked background job; inherits all _nh_* functions + `set -g` state). Sleeps the debounce,
# double-checks the generation (debounce-cancel), queries the daemon, runs the pure pipeline (which
# enforces the control-char + range guards — the security backstop), re-checks the generation
# immediately before any screen write, then PAINTS BEFORE STASHING so accept can never fire on an
# unseen ghost: if the worker dies between paint and stash the user merely saw a ghost with no stash,
# and accept no-ops (the ghost clears on the next key). Every dispatch bumps the gen first, so each
# worker carries a unique gen0 and a same-gen double-stash is unreachable. Args: <gen0> <buffer>
# <cursor_bytes> (cursor_bytes is the EOL byte offset computed by dispatch).
function _nh_worker
    set -l gen0 $argv[1]
    set -l buf $argv[2]
    set -l cur $argv[3]
    # Run dir as an ARG (argv[4]): the detached worker runs in a fresh fish that never executed the
    # interactive _nh_state_init, so its _nh_run_dir global is empty. Fall back to the global so an
    # in-process foreground call (tests / future callers that DO have the global) still works 3-arg.
    set -l rundir $argv[4]
    test -n "$rundir"; or set rundir $_nh_run_dir
    test -n "$rundir"; or return 0
    sleep $_nh_debounce_sec
    test (cat "$rundir/gen" 2>/dev/null) = "$gen0"; or return 0
    set -l req (_nh_build_request "$buf" "$cur" "$PWD")
    test -n "$req"; or return 0
    set -l resp (_nh_request "$req")
    test -n "$resp"; or return 0
    set -l out (_nh_compute_suggestion "$buf" "$resp")
    test -n "$out"; or return 0
    # Post-IPC staleness AND last-chance ENOENT (teardown) check, immediately before any write.
    test (cat "$rundir/gen" 2>/dev/null) = "$gen0"; or return 0
    # Split the 5-field record <kind>\t<display>\t<bstart>\t<bend>\t<text>; -m 4 keeps any tab in text
    # (rejected upstream anyway) inside field 5. The accept path wants bstart/bend/text (fields 3-5).
    set -l fields (string split -m 4 \t -- $out)
    # (a) PAINT first (the single /dev/tty sink, via the H2 composition) so accept can never fire on an
    # unseen ghost. _nh_paint_ghost re-runs the control-char guard as the last gate before the terminal.
    _nh_paint_ghost "$out"
    # (b) then STASH atomically: mktemp a unique temp in the run dir, write, then `mv -f` (rename is
    # atomic on the same filesystem) so _nh_accept (H4) never reads a half-written stash. mktemp (not
    # a $fish_pid-named temp) because two racing workers (re-exec'd from the same shell) would
    # otherwise collide on one name. A fork here is fine — we're off the keystroke.
    set -l tmp (mktemp "$rundir/.stash.XXXXXXXX" 2>/dev/null)
    test -n "$tmp"; or return 0
    printf '%s\t%s\t%s\t%s' "$gen0" "$fields[3]" "$fields[4]" "$fields[5]" >"$tmp" 2>/dev/null
    and mv -f "$tmp" "$rundir/stash" 2>/dev/null
end

# --- H4 accept-splice (PURE kernel) + interactive key handlers ---
# The live layer's last piece: the keys that fire _nh_dispatch and accept/dismiss the ghost the worker
# painted. fish's editor is reached through `commandline`, which only works inside a key binding, so the
# accept REVALIDATION (the security-critical part) is factored into a PURE _nh_accept_splice the harness
# can drive directly; the rest are thin `commandline` wrappers. All are defined HERE (above the dep
# check + interactive guard) so the structural harness sees them; only the `bind` calls in the live
# layer below are interactive-gated, so nothing fires until a real key is pressed.

# Per-keystroke change-gate snapshot: the prior buffer + cursor _nh_keypress compares against, so a
# no-op binding (e.g. delete-char at EOL) can't clear a live ghost or re-fire the daemon. The -1 cursor
# sentinel makes the first real keystroke always count as a change. Reset on every (re-)source.
set -g _nh_last_buf ""
set -g _nh_last_cursor -1

# Validate-and-splice the worker's stashed suggestion against LIVE state (PURE). Ports the bash sibling's
# accept revalidation (nighthawk.bash _nh_accept) — the stash is a CROSS-PROCESS suggestion, so accept
# must re-check it before mutating the buffer. Defenses, in order:
#   sgen == curgen   the suggestion is for the CURRENT generation (a changed buffer bumped the gen, so a
#                    superseded stash is rejected — the core staleness guarantee).
#   bstart/bend digits.
#   control-char RE-guard on text  the NON-NEGOTIABLE last backstop against a planted-newline auto-submit
#                    / ESC hijack (see the H3 forward note); the worker already guarded, but accept must
#                    never trust a file another process wrote.
#   cursor at EOL    CODE-POINT domain (`commandline --cursor` is code points) — a stash can outlive an
#                    unbound cursor move. NOT byte-domain like bash's READLINE_POINT.
#   byte->char in range  the daemon's BYTE offsets must land on code-point boundaries (fail-closed -1).
# On success prints "<newcursor>\t<newbuffer>" — cursor FIRST so the variable-width buffer (which could
# carry a pasted tab) is the unsplit LAST field; prints NOTHING (status 1) on any reject. The splice is
# CODE-POINT domain because fish `commandline` is (bash splices in bytes — its buffer IS byte-indexed).
# Args: <buffer> <cursor_chars> <curgen> <sgen> <bstart> <bend> <text>
function _nh_accept_splice
    set -l buffer $argv[1]
    set -l cursor $argv[2]
    set -l curgen $argv[3]
    set -l sgen $argv[4]
    set -l bstart $argv[5]
    set -l bend $argv[6]
    set -l text $argv[7]
    test "$sgen" = "$curgen"; or return 1
    string match -rq '^[0-9]+$' -- "$bstart"; and string match -rq '^[0-9]+$' -- "$bend"; or return 1
    _nh_has_ctrl_char "$text"; and return 1
    test "$cursor" = (string length -- "$buffer"); or return 1
    set -l cstart (_nh_byte_to_char "$buffer" "$bstart")
    set -l cend (_nh_byte_to_char "$buffer" "$bend")
    test $cstart -ge 0 -a $cend -ge 0 -a $cend -ge $cstart; or return 1
    set -l before (string sub -l $cstart -- "$buffer")
    set -l after (string sub -s (math $cend + 1) -- "$buffer")
    set -l newbuf "$before$text$after"
    printf '%s\t%s' (math (string length -- "$before") + (string length -- "$text")) "$newbuf"
end

# Per-keystroke snapshot + trigger. Bound (chained AFTER fish's own self-insert / delete input function)
# to every buffer-mutating key. Snapshots the POST-edit buffer + CODE-POINT cursor, gates on a real
# change, then hands them to the non-blocking _nh_dispatch. `commandline` lives ONLY in these wrappers,
# so _nh_dispatch and the kernels stay testable.
function _nh_keypress
    set -l buf (commandline -b)
    set -l cur (commandline --cursor)
    _nh_input_changed "$_nh_last_buf" "$_nh_last_cursor" "$buf" "$cur"; or return 0
    set -g _nh_last_buf "$buf"
    set -g _nh_last_cursor "$cur"
    _nh_dispatch "$buf" "$cur"
end

# Accept precondition: a live stash exists AND the cursor is at EOL (code-point domain). The single gate
# the accept-key handlers check before delegating to _nh_accept (which re-validates authoritatively, so
# this can stay a cheap pre-check).
function _nh_stash_ready
    test -n "$_nh_run_dir"; and test -f "$_nh_run_dir/stash"; or return 1
    set -l buf (commandline -b)
    test (commandline --cursor) = (string length -- "$buf")
end

# Accept the stashed suggestion: read the worker's cross-process stash, snapshot LIVE buffer/cursor,
# revalidate+splice via the pure _nh_accept_splice, and (only on success) replace the buffer + reposition
# the cursor. Clears the ghost on EVERY path so a rejected/stale suggestion can never leave a painted
# ghost behind (slightly stricter than bash, which skips the clear on its unreachable non-digit branch).
# The stash is split `-m 3` (text LAST keeps any tab inside it in field 4); `string collect -N` keeps a
# newline-terminated payload intact so a reject stays a reject (never a silent strip-and-accept).
function _nh_accept
    test -n "$_nh_run_dir"; and test -f "$_nh_run_dir/stash"; or return 0
    set -l stash (cat "$_nh_run_dir/stash" 2>/dev/null | string collect -N)
    set -l fields (string split -m 3 \t -- $stash)
    test (count $fields) -ge 4; or begin
        _nh_clear_ghost
        return 0
    end
    set -l buffer (commandline -b)
    set -l cursor (commandline --cursor)
    set -l spliced (_nh_accept_splice "$buffer" "$cursor" "$_nh_gen" "$fields[1]" "$fields[2]" "$fields[3]" "$fields[4]" | string collect -N)
    _nh_clear_ghost
    test -n "$spliced"; or return 0
    set -l parts (string split -m 1 \t -- $spliced)
    commandline -r -- "$parts[2]"
    commandline -C $parts[1]
end

# RightArrow / Ctrl-F: accept at EOL with a live stash; otherwise drop the ghost, invalidate in-flight
# workers, and fall through to fish's native forward-char (multibyte-correct — no reimplement needed,
# unlike bash). Native autosuggestion is off (H1), so these keys are ours with no forward-char race.
function _nh_forward_or_accept
    if _nh_stash_ready
        _nh_accept
        return 0
    end
    _nh_clear_ghost
    _nh_bump_gen
    commandline -f forward-char
end

# Tab: ALWAYS clear the ghost + invalidate first (so a lingering ghost never overlaps the completion
# pager), then either accept or complete. With tab_accept ON and a live ghost at EOL -> accept it; else
# fall through to fish's native `complete`. Unlike bash's bind -x (which CANNOT delegate to native
# completion, so its opt-in Tab gives completion up entirely), `commandline -f complete` preserves Tab
# completion whether or not accept is enabled — so binding Tab unconditionally has no downside, and it
# fixes the ghost-over-pager artifact. Right-arrow + Ctrl-F accept regardless of this setting.
function _nh_tab_widget
    if test "$_nh_tab_accept" = 1; and _nh_stash_ready
        _nh_accept
        return 0
    end
    _nh_clear_ghost
    _nh_bump_gen
    commandline -f complete
end

# Escape: dismiss the ghost + invalidate any in-flight worker.
function _nh_dismiss
    _nh_clear_ghost
    _nh_bump_gen
end

# Bound cursor MOTIONS: clear the ghost + invalidate in-flight workers, THEN run fish's native motion
# (closes the "worker paints after a cursor move" window for the common keys — the bash sibling's fix).
# Pure native motions, so no reimplement — just clear-then-delegate.
function _nh_cursor_left
    _nh_clear_ghost
    _nh_bump_gen
    commandline -f backward-char
end
function _nh_cursor_home
    _nh_clear_ghost
    _nh_bump_gen
    commandline -f beginning-of-line
end
function _nh_cursor_end
    _nh_clear_ghost
    _nh_bump_gen
    commandline -f end-of-line
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
#   H2 (done):  ghost rendering primitives (clear/paint/render seqs + the /dev/tty sink) — above.
#   H3 (below): async / non-blocking IPC + debounce timer (fish is single-threaded: no `zle -F`
#               fd-callbacks, no RunspacePool). The state functions are defined above; here we
#               initialize the per-session run dir and arm teardown. H4 binds the keys that fire it.
#   H4 (below): key bindings + live loop: per-keystroke insert+trigger, accept (Right/Ctrl-F; Tab
#               opt-in via _nh_tab_accept), Escape dismiss, cursor motions, Enter-clear. The handler
#               functions are defined above; here we install the bindings that drive them.
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

# --- H3: per-session async state init + teardown ---
# Create the nonce'd run dir (gen + stash live here) for THIS interactive shell. Re-sourcing is safe:
# _nh_state_init reaps this shell's prior-load dir (orphaning its in-flight workers via the ENOENT
# `gen` read) before minting a fresh one. A failed mktemp leaves _nh_run_dir empty, so every live
# helper degrades to a no-op rather than erroring on the keystroke path. The function definitions live
# ABOVE the dep check so the unit harness can drive them with an injected run dir; only this CALL is
# interactive-gated. H4's bindings are what actually fire _nh_dispatch.
_nh_state_init

# --- H4: key bindings (the live loop) ---
# Every binding is installed ONLY here (inside the interactive guard); the handlers are defined above
# the dep check so the unit harness sees them but nothing fires them. Re-sourcing is safe — `bind` is
# idempotent (rebinding a key replaces it) and _nh_state_init reset the snapshot + run dir above.
#
# Per-keystroke insert + trigger. fish's `bind '' self-insert` is the catch-all for any printable key
# with NO explicit binding, so chaining _nh_keypress onto it covers the whole alphabet in ONE binding
# (bash needed ~70 explicit char binds). BUT seven chars carry their OWN preset binding
# `self-insert expand-abbr` (space + the abbr-triggering metacharacters ; | & > < ) ), which SHADOWS the
# catch-all default — each must be re-bound with the trigger appended or typing them wouldn't fire it.
# `expand-abbr` is kept so fish abbreviations still expand; _nh_keypress then snapshots the POST-expansion
# buffer.
bind '' self-insert _nh_keypress
for _nh_k in space ';' '|' '&' '>' '<' ')'
    bind $_nh_k self-insert expand-abbr _nh_keypress
end
set -e _nh_k

# Deletions: let fish run its native (multibyte-correct) delete, THEN snapshot + re-dispatch — no
# bash-style reimplemented char-domain delete, because fish's input functions already do the grapheme math.
bind backspace backward-delete-char _nh_keypress
bind ctrl-h backward-delete-char _nh_keypress
bind delete delete-char _nh_keypress

# Accept keys: RightArrow + Ctrl-F ALWAYS accept at EOL (native autosuggestion is off, so they own those
# keys with no forward-char race). Tab always clears + completes; it additionally ACCEPTS only when
# tab_accept is on (opt-in, default off — see _nh_tab_widget).
bind right _nh_forward_or_accept
bind ctrl-f _nh_forward_or_accept
bind tab _nh_tab_widget

# Cursor MOTIONS: clear ghost + invalidate, then native move (closes the mid-line stale-paint window).
# Left (+ Ctrl-B), Home (+ Ctrl-A), End (+ Ctrl-E). Up/Down are intentionally left native — clearing on
# them risks erasing the history-search UI (the documented bash-sibling limitation: an in-flight worker
# may paint once after Up/Down; the next bound key clears it).
bind left _nh_cursor_left
bind ctrl-b _nh_cursor_left
bind home _nh_cursor_home
bind ctrl-a _nh_cursor_home
bind end _nh_cursor_end
bind ctrl-e _nh_cursor_end

# Escape: dismiss the ghost, then run fish's native `cancel` (so Esc still closes a completion pager).
# fish's modern key parser distinguishes a lone Esc from arrow/Alt escape sequences via the escape
# timeout, so this coexists with the \e[… arrows — but it is the highest-risk binding (verify arrows
# still work in the hands-on test).
bind escape _nh_dismiss cancel

# Enter: dismiss the ghost AND bump the generation, then submit via fish's native `execute` (which still
# decides submit-vs-insert-newline for an incomplete command). The gen bump (vs the bash sibling's clear-
# only) ORPHANS any worker still in its debounce when Enter is pressed — it wakes, sees the gen advanced
# past its gen0, and exits instead of painting a stray ghost onto the fresh prompt. fish gets this fix
# for free (bash's macro-based Enter binding made it awkward there); verify no stray artifact on submit.
bind enter _nh_dismiss execute

# Defensive: drop any ghost state at load (e.g. re-source while a ghost was on screen).
_nh_clear_ghost

# Tear the run dir down on shell exit. fish's `fish_exit` event is the idiom (no bash-style EXIT trap
# chaining needed — redefining this handler on a re-source just replaces it, and multiple listeners can
# coexist on the event, so we never clobber a user's own fish_exit handler). HUP/KILL/crash are covered
# by the dead-PID GC in _nh_state_init on the next shell's load.
function _nh_on_exit --on-event fish_exit
    _nh_cleanup
end
