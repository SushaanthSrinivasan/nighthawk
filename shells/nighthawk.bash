#!/usr/bin/env bash
# nighthawk bash plugin — inline ghost text autocomplete
#
# Install: add to ~/.bashrc:  source /path/to/nighthawk.bash
# Requires: socat, jq
#
# Architecture:
#   bash has no POSTDISPLAY (zsh) or PSReadLine prediction (PowerShell), so ghost
#   text is drawn with raw ANSI escapes (PowerShell's model). bind -x hooks readline;
#   READLINE_LINE/READLINE_POINT are the live buffer/cursor (POINT is a BYTE offset).
#
# This file is the SESSION-1 layer: the pure, side-effect-free helpers (config,
# logging, control-char guard, UTF-8 offset conversion, JSON request build, response
# parse, prefix-vs-hint decision) plus a thin pipeline that composes them. It loads
# but is otherwise INERT — no key bindings, no rendering. Session 2 adds rendering +
# bindings; Session 3 adds the async IPC core. The helpers are factored exactly so the
# later sessions compose them without re-deriving any of this logic — mirroring how the
# PowerShell plugin factored its $_nh_worker body.

NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"

# --- Configuration ---
# Defaults mirror the PowerShell plugin's keys. The arrow differs by design: bash/PS use
# ASCII "->", zsh keeps the Unicode "→". Config dir matches the daemon's resolution
# (dirs::config_dir() == ${XDG_CONFIG_HOME:-$HOME/.config}/nighthawk on Linux/WSL).
_nh_hint_arrow="->"
_nh_debounce_ms=200
_nh_debug=0
_nh_log_path="${XDG_CONFIG_HOME:-$HOME/.config}/nighthawk/plugin.log"

# Minimal hand-rolled TOML reader: walks lines, tracks the current [section], and pulls
# the three keys we care about from [plugin]. No real parser, to stay dep-free.
#
# Two bash-specific load-bearing details vs. the zsh sibling:
#   - The ERE patterns are stored in vars and used UNQUOTED on the right of `=~`. A
#     quoted regex literal in bash is matched LITERALLY, which would silently make every
#     line fail to match and config parsing a no-op (defaults always win). Single-quoting
#     the assignment keeps the metacharacters intact without premature expansion.
#   - The loop reads via `done < "$file"` REDIRECTION, never a pipe: a piped `while`
#     runs in a subshell and the _nh_* assignments would be lost on exit.
# `BASH_REMATCH` is clobbered by the next `=~`, so each capture is consumed immediately.
_nh_load_config() {
    local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/nighthawk/config.toml"
    [[ -f "$config_file" ]] || return 0
    local re_section='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
    local re_arrow='^[[:space:]]*hint_arrow[[:space:]]*=[[:space:]]*"([^"]*)"'
    local re_debounce='^[[:space:]]*debounce_ms[[:space:]]*=[[:space:]]*([0-9]+)'
    local re_debug='^[[:space:]]*debug[[:space:]]*=[[:space:]]*(true|false)'
    local line in_plugin=0
    # `|| [[ -n "$line" ]]` processes a final line with no trailing newline, which `read`
    # would otherwise drop. A trailing CRLF \r from a Windows-edited file is harmless: the
    # value regexes capture before it, and \r is in [[:space:]] so the section anchor still
    # matches "[plugin]\r".
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re_section ]]; then
            [[ "${BASH_REMATCH[1]}" == plugin ]] && in_plugin=1 || in_plugin=0
            continue
        fi
        (( in_plugin )) || continue
        if [[ "$line" =~ $re_arrow ]]; then
            _nh_hint_arrow="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $re_debounce ]]; then
            _nh_debounce_ms="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $re_debug ]]; then
            [[ "${BASH_REMATCH[1]}" == true ]] && _nh_debug=1 || _nh_debug=0
        fi
    done < "$config_file"
}
_nh_load_config

# Env vars win over config.toml (precedence env > file > default).
[[ -n "$NIGHTHAWK_HINT_ARROW" ]] && _nh_hint_arrow="$NIGHTHAWK_HINT_ARROW"
[[ -n "$NIGHTHAWK_DEBOUNCE_MS" ]] && _nh_debounce_ms="$NIGHTHAWK_DEBOUNCE_MS"
if [[ -n "$NIGHTHAWK_DEBUG" ]]; then
    [[ "$NIGHTHAWK_DEBUG" == "1" ]] && _nh_debug=1 || _nh_debug=0
fi

# Validate debounce_ms before it ever reaches arithmetic. The config regex only accepts
# digits, but the env override is unguarded — a stray NIGHTHAWK_DEBOUNCE_MS=foo would
# otherwise throw from inside the keystroke path. Reset to default on non-digit input,
# then normalize with the base-10 prefix so a leading-zero value (e.g. "0200") is NOT
# parsed as octal by $(( )).
[[ "$_nh_debounce_ms" =~ ^[0-9]+$ ]] || _nh_debounce_ms=200
_nh_debounce_ms=$(( 10#$_nh_debounce_ms ))

# --- Diagnostic logging ---
# No-op unless debug is on. Millisecond timestamps via GNU date's %N (Linux/WSL); on a
# non-GNU date the literal "%3N" appears in the log — harmless, and never aborts.
_nh_log() {
    (( _nh_debug )) || return 0
    printf '%s %s\n' "$(date '+%H:%M:%S.%3N' 2>/dev/null)" "$1" >> "$_nh_log_path" 2>/dev/null
}

# --- Control-char guard ---
# True if $1 contains a C0 control char (0x01-0x1f) or DEL (0x7f). Single source of truth
# for the fail-closed rejection of daemon suggestions before they reach the buffer: an
# embedded newline auto-submits on accept (single-keystroke RCE if a model emits
# `rm -rf $HOME\n`); an embedded ESC hijacks the terminal during render. Shell commands
# never legitimately contain control chars, so reject (never strip — stripping merges
# tokens around the dropped byte). `local LC_ALL=C` forces byte semantics so the bracket
# RANGE uses C collation (a UTF-8 locale would make the range match unpredictably and
# could let a control char slip or falsely reject a multibyte char). 0x00 is unreachable —
# a literal NUL can't survive command substitution — so the floor is 0x01.
_nh_has_ctrl_char() {
    local LC_ALL=C
    [[ $1 == *[$'\x01'-$'\x1f']* || $1 == *$'\x7f'* ]]
}

# --- UTF-8 byte offset <-> char index conversion ---
# The daemon speaks UTF-8 BYTE offsets (replace_start/replace_end and the request cursor);
# bash buffer subscripts and READLINE_POINT math need CHAR indices under a UTF-8 locale.
# These bridge the two. The mechanic, validated empirically: a char-domain slice taken in
# the ambient UTF-8 locale, then re-measured under `local LC_ALL=C`, yields that slice's
# byte length. The locale flip is per-function and never leaks. Both fail CLOSED (-1 / a
# clamp) so a malformed offset can never corrupt the buffer.
#
# CRITICAL ordering: the char-slice expansion (${s:0:n} / ${s:c-1:1}) MUST happen while the
# UTF-8 CTYPE is still active; only the ${#...} measurement runs under LC_ALL=C. Putting
# LC_ALL=C on the same `local` line as a slice would slice by byte and be silently wrong.

# Byte offset -> char index (count of leading chars). Fail-closed -1 for a negative offset,
# one past the end, or one landing inside a multibyte sequence (detected by overshoot).
_nh_byte_to_char() {
    local s=$1 boff=$2
    (( boff < 0 )) && { printf '%s' -1; return; }
    (( boff == 0 )) && { printf '%s' 0; return; }
    local n=${#s} c                       # n = char count (UTF-8)
    local -a chars=()
    for (( c = 1; c <= n; c++ )); do chars[c]=${s:c-1:1}; done   # per-char slices (UTF-8)
    local LC_ALL=C                        # measure byte widths under C, single context
    local acc=0
    for (( c = 1; c <= n; c++ )); do
        (( acc += ${#chars[c]} ))
        (( acc == boff )) && { printf '%s' "$c"; return; }   # exact code-point boundary
        (( acc > boff )) && { printf '%s' -1; return; }      # offset split a multibyte char
    done
    printf '%s' -1                        # offset past the last byte
}

# Char index -> byte offset. One slice + measure (no walk needed). Clamps an over-long
# index to the char length; returns 0 for <= 0.
_nh_char_to_byte() {
    local s=$1 cidx=$2
    (( cidx <= 0 )) && { printf '%s' 0; return; }
    local n=${#s}                         # char count (UTF-8)
    (( cidx > n )) && cidx=$n
    local slice=${s:0:cidx}               # char-domain slice, taken in UTF-8
    local LC_ALL=C                        # now measure its bytes
    printf '%s' "${#slice}"
}

# --- JSON string escaping ---
# SINGLE source of request-side escaping; _nh_build_request delegates here. This is the
# OUTBOUND direction (serializing the user's own buffer / cwd) and is independent of the
# inbound _nh_has_ctrl_char rejection: a literal tab or newline pasted into the buffer is
# illegal raw inside a JSON string (RFC 8259), so the daemon would reject the whole
# request — hence the full control-char set, matching the PowerShell escaper. Chars >=0x20
# (including all multibyte UTF-8) pass through RAW so the daemon's byte offsets over the
# input agree with ours.
_nh_json_escape() {
    local s=$1
    s=${s//\\/\\\\}        # backslash first
    s=${s//\"/\\\"}        # then quote
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Remaining C0 control chars (0x01-0x1f minus the named ones above) -> \u00XX. The
    # quoted "$ctrl" makes each a LITERAL single-byte substring match (no locale-sensitive
    # range), so no LC_ALL needed. Rare in shell input; 26 cheap checks on a short string.
    local code octal ctrl hex
    for code in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
        printf -v octal '%03o' "$code"
        printf -v ctrl "\\$octal"
        [[ "$s" == *"$ctrl"* ]] || continue
        printf -v hex '\\u%04x' "$code"
        s=${s//"$ctrl"/$hex}
    done
    printf '%s' "$s"
}

# --- Request build ---
# Pure string -> string. Takes the cursor ALREADY converted to a byte offset (the
# char->byte conversion belongs at snapshot time in the S3 dispatch, not here). Emits
# "shell":"bash" so the daemon routes to bash history / detection.
_nh_build_request() {
    local input=$1 cursor_bytes=$2 cwd=$3
    printf '{"input":"%s","cursor":%s,"cwd":"%s","shell":"bash"}' \
        "$(_nh_json_escape "$input")" "$cursor_bytes" "$(_nh_json_escape "$cwd")"
}

# --- Response parse ---
# Emits eval-able assignments for the first suggestion: text / replace_start / replace_end
# (jq @sh-quoted) and a bare diff_ops_present 0|1 flag. The caller MUST declare these as
# locals (defaulted) BEFORE `eval "$(_nh_parse_response ...)"` so a jq failure (malformed
# JSON, swallowed by 2>/dev/null) leaves them empty rather than stale from a prior call.
# Only suggestions[0] is used, matching the zsh/PowerShell plugins.
_nh_parse_response() {
    printf '%s' "$1" | jq -r '
        if (.suggestions | length) > 0 then
            "text=" + (.suggestions[0].text | @sh)
            + " replace_start=" + ((.suggestions[0].replace_start | tostring) | @sh)
            + " replace_end=" + ((.suggestions[0].replace_end | tostring) | @sh)
            + " diff_ops_present=" + (if (.suggestions[0].diff_ops // null) then "1" else "0" end)
        else
            "text=" + ("" | @sh) + " replace_start=" + ("" | @sh)
            + " replace_end=" + ("" | @sh) + " diff_ops_present=0"
        end
    ' 2>/dev/null
}

# --- Prefix-vs-hint decision ---
# Pure. Echoes a tagged, display-ready payload for the S2 renderer to dispatch on:
#   ghost<TAB><suffix>   true prefix match — render <suffix> as ghost after the cursor
#   hint<TAB> -> <text>  replacement / fuzzy — render as a hint
#   (empty)              nothing to show
# bash follows the PowerShell hint-only model: a fuzzy match (diff_ops present) always
# renders as a hint; there is no inline-diff renderer. <rstart_chars> is the CHAR-domain
# replace_start (already byte->char converted). Self-guards rstart so a -1 from a failed
# conversion can never reach the ${buffer:rstart:...} subscript across the S2/S3 seam.
# <snapshot_buffer> MUST be the same buffer snapshot whose bytes fed _nh_build_request and
# the offset conversion — never live READLINE_LINE. Typed length is derived from the buffer
# length because the suggest path only ever fires with the cursor at end-of-line.
_nh_decide_render() {
    local buffer=$1 text=$2 rstart=$3 diff_present=$4
    [[ -n "$text" ]] || return 0
    [[ "$rstart" =~ ^[0-9]+$ ]] || return 0
    local blen=${#buffer}
    (( rstart > blen )) && return 0
    if (( diff_present )); then
        printf 'hint\t %s %s' "$_nh_hint_arrow" "$text"
        return 0
    fi
    local typed_len=$(( blen - rstart ))
    (( typed_len >= 0 && typed_len < ${#text} )) || return 0
    local typed_part=${buffer:rstart:typed_len}
    if [[ "${text:0:typed_len}" == "$typed_part" ]]; then
        printf 'ghost\t%s' "${text:typed_len}"      # true prefix: suffix as ghost
    else
        printf 'hint\t %s %s' "$_nh_hint_arrow" "$text"   # replacement: hint
    fi
}

# --- Response pipeline (pure) ---
# Composes parse -> control-char reject -> byte->char convert -> range-validate -> decide
# against a buffer SNAPSHOT and a raw daemon reply, echoing the _nh_decide_render result.
# Kept as one tested seam (the bash counterpart of the zsh _nh_handle_response body) so the
# S3 async path can drive it with a canned reply; S2 only adds the actual render of the tag.
_nh_compute_suggestion() {
    local buffer=$1 response=$2
    local text='' replace_start='' replace_end='' diff_ops_present=0
    eval "$(_nh_parse_response "$response")"
    [[ -n "$text" ]] || return 0
    # Fail-closed: drop any suggestion carrying a control char before it can be rendered
    # or accepted.
    if _nh_has_ctrl_char "$text"; then
        _nh_log "rejected: control char in suggestion"
        return 0
    fi
    # Reject a non-integer range (e.g. "null" from a malformed reply) before arithmetic.
    [[ "$replace_start" =~ ^[0-9]+$ && "$replace_end" =~ ^[0-9]+$ ]] || return 0
    # Protocol byte offsets -> char indices against the snapshot buffer. Fail closed if
    # either is out of range or splits a multibyte char.
    local rstart rend
    rstart=$(_nh_byte_to_char "$buffer" "$replace_start")
    rend=$(_nh_byte_to_char "$buffer" "$replace_end")
    if (( rstart < 0 || rend < 0 || rend < rstart )); then
        _nh_log "rejected: replace range not on a code-point boundary"
        return 0
    fi
    _nh_decide_render "$buffer" "$text" "$rstart" "$diff_ops_present"
}

# --- Dependency check ---
# After the pure helpers (mirrors nighthawk.zsh ordering) so the unit harness can source
# this file and exercise the helpers structurally even on a machine without the deps — and
# so a "helper not defined" test failure means "renamed", not "deps missing".
if ! command -v socat >/dev/null 2>&1; then
    echo "nighthawk: socat not found, install with: apt install socat" >&2
    return 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "nighthawk: jq not found, install with: apt install jq" >&2
    return 1
fi

# --- Inert placeholders ---
# Session 2 wires rendering + readline key bindings (bind -x); Session 3 wires async IPC.
# Defined as no-ops so the plugin loads cleanly without yet touching terminal state.
_nh_suggest() { :; }
_nh_accept()  { :; }
