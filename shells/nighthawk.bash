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
# bash-ONLY opt-in: bind Tab to accept the suggestion. Default OFF because, unlike zsh/PowerShell
# (whose editors can fall back to native completion via `zle expand-or-complete` / `TabCompleteNext`),
# bash's `bind -x` CANNOT invoke readline completion — so binding Tab here means giving up native
# Tab-completion when no suggestion is showing. Right arrow + Ctrl-F are always accept keys regardless.
_nh_tab_accept=0
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
    local re_tab='^[[:space:]]*tab_accept[[:space:]]*=[[:space:]]*(true|false)'
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
        elif [[ "$line" =~ $re_tab ]]; then
            [[ "${BASH_REMATCH[1]}" == true ]] && _nh_tab_accept=1 || _nh_tab_accept=0
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
if [[ -n "$NIGHTHAWK_TAB_ACCEPT" ]]; then
    [[ "$NIGHTHAWK_TAB_ACCEPT" == "1" ]] && _nh_tab_accept=1 || _nh_tab_accept=0
fi

# Validate debounce_ms before it ever reaches arithmetic. The config regex only accepts
# digits, but the env override is unguarded — a stray NIGHTHAWK_DEBOUNCE_MS=foo would
# otherwise throw from inside the keystroke path. Reset to default on non-digit input,
# then normalize with the base-10 prefix so a leading-zero value (e.g. "0200") is NOT
# parsed as octal by $(( )).
[[ "$_nh_debounce_ms" =~ ^[0-9]+$ ]] || _nh_debounce_ms=200
_nh_debounce_ms=$(( 10#$_nh_debounce_ms ))

# Integer-ms -> fractional-seconds for the worker's debounce `sleep` (Session 3). Bash has no
# float math, so this is pure STRING SPLICING: floor to a 10ms minimum (ms=0 would mean
# `sleep 0` = NO debounce = a socat-fork-per-keystroke storm), zero-pad to >=4 digits, then
# splice a "." three places from the right. The zero-pad is load-bearing: 50 -> "0050" -> "0.050"
# (NOT "0.50", the silent 10x bug). The SPACE in ${p: -3} is also load-bearing — ${p:-3} (no
# space) is the default-value operator and would yield "0050.0050". Input is already 10#-normalized
# above, so printf only ever sees a clean decimal (no octal/sign surprise); %04d guarantees >=4
# chars so the integer part (strip 3) is never empty. Kept a pure function so the harness can
# assert the rows (200->0.200, 50->0.050, 1500->1.500, 10000->10.000, 10->0.010, 0->0.010).
_nh_ms_to_sec() {
    local ms=$1 p
    (( ms < 10 )) && ms=10
    printf -v p '%04d' "$ms"
    printf '%s' "${p%???}.${p: -3}"
}
_nh_debounce_sec=$(_nh_ms_to_sec "$_nh_debounce_ms")

# --- Live-state (Session 3: async direct-paint) ---
# bash has no POSTDISPLAY (zsh) or `zle -F` fd-callback, so async rendering is done by a
# background WORKER that paints the ghost straight to /dev/tty and round-trips the accept
# payload through a `stash` FILE. These globals hold the cross-process coordination state.
#   _nh_esc            ESC byte for the ANSI ghost sequences.
#   _nh_gen            monotonic generation counter (in-process authority). Bumped on every
#                      bound keystroke; mirrored to "$_nh_run_dir/gen" at dispatch so a worker
#                      can detect it was superseded. The SOLE staleness token.
#   _nh_run_dir        per-load nonce'd dir holding `gen` + `stash` (set by _nh_state_init in the
#                      interactive guard; empty when sourced non-interactively => helpers no-op).
#   _nh_backoff_until  epoch-seconds gate; a missing socket arms a 5s backoff so dispatch can't
#                      hammer a dead daemon. (A present-but-hung daemon just costs one off-thread
#                      worker that eats socat -t3 — never a freeze, so no cross-process marker.)
# RETIRED vs S2: _nh_ghost_len (presence is now stash-file existence; clear is unconditional),
# _nh_sug_text/_nh_sug_bstart/_nh_sug_bend (the accept payload is cross-process now — it lives in
# the `stash` file), and _nh_render_ghost (folded into the worker's single _nh_tty_write sink).
_nh_esc=$'\033'
_nh_gen=0
_nh_run_dir=""
_nh_backoff_until=0

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

# Byte length of a whole string == the byte offset of its EOL. This is the load-bearing
# "is the cursor (READLINE_POINT, a byte offset) at end-of-line?" quantity — factored out so
# _nh_dispatch/_nh_worker and _nh_forward_or_accept/_nh_accept compute it identically and can't
# drift. NOT ${#1}, which is a CHAR count under a UTF-8 locale and wrong for the byte-offset
# comparison.
_nh_eol_bytes() { _nh_char_to_byte "$1" "${#1}"; }

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
# (jq @sh-quoted) and a bare diff_ops_present 0|1 flag. SELF-DEFAULTING: all four assignments
# are emitted empty/0 FIRST (a fixed literal outside jq), so even a jq crash — malformed JSON
# swallowed by 2>/dev/null, producing no output at all — still resets every field rather than
# leaving it stale from a prior call. On success the jq assignments that follow (after the
# `;`) override the defaults. The caller therefore only needs to declare these `local` for
# scoping; it need not pre-default them. Only suggestions[0] is used, matching zsh/PowerShell.
# diff_ops is reduced to a PRESENCE flag (not extracted) because bash is hint-only — there is
# no inline-diff renderer (see CLAUDE.md / the no-inline-diff decision). A future session that
# adds inline-diff rendering MUST also port zsh's separate control-char guard over the per-op
# `ch` bytes (zsh _nh_handle_response); those bytes bypass the `_nh_has_ctrl_char "$text"`
# check and would otherwise reintroduce the newline/ESC injection vector this plugin closes.
_nh_parse_response() {
    printf "text='' replace_start='' replace_end='' diff_ops_present=0;"
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
#   ghost<TAB><suffix>     true prefix match — render <suffix> as ghost after the cursor
#   hint<TAB> -> <text>    replacement / fuzzy — render as a hint
#   (empty)                nothing to show
# This 2-field `<tag>\t<payload>` shape is _nh_decide_render's OWN contract. _nh_compute_suggestion
# wraps it with three more fields (byte range + replacement text) for the accept path — see there;
# the FIRST-TAB split below still recovers tag/payload from either shape.
# S2 PARSE CONTRACT: split on the FIRST TAB (e.g. `IFS=$'\t' read -r tag payload`). The
# hint payload's LEADING SPACE is load-bearing — it is part of the rendered prefix
# (" -> <text>"), matching the leading space the zsh/PS renderers prepend; S2 MUST emit
# <payload> verbatim and never trim or word-split it. The ghost branch prepends no separator
# (its payload is the raw suffix, which may itself legitimately begin with a space).
# bash follows the PowerShell hint-only model: a fuzzy match (diff_ops present) always
# renders as a hint; there is no inline-diff renderer. <rstart_chars> is the CHAR-domain
# replace_start (already byte->char converted). Self-guards rstart so a -1 from a failed
# conversion can never reach the ${buffer:rstart:...} subscript across the S2/S3 seam.
# <snapshot_buffer> MUST be the same buffer snapshot whose bytes fed _nh_build_request and
# the offset conversion — never live READLINE_LINE.
# CURSOR INVARIANT: unlike the zsh/PS siblings (which compute typed_len = cursor - rstart),
# this derives typed_len = ${#buffer} - rstart, i.e. it assumes the cursor sits at
# end-of-line. That holds because the suggest path only ever fires at EOL, so no cursor
# parameter is taken. The S3 caller MUST preserve that invariant (snapshot the buffer with
# cursor == buffer end); if mid-line suggestions are ever added, this needs an explicit
# cursor argument to match the siblings.
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
# against a buffer SNAPSHOT and a raw daemon reply. Output is the 5-field record
#   <kind>\t<display>\t<bstart>\t<bend>\t<text>
# (empty when there is nothing to show): the 2-field display tag from _nh_decide_render plus
# the daemon's BYTE range and full replacement text for the accept path. _nh_worker splits it
# (IFS=$'\t'), paints <display>, and writes gen0/bstart/bend/text to the `stash` FILE that
# _nh_accept reads — the stash file is the durable cross-process interface, so the async worker
# can drive this with a real reply and stash identically without re-splitting anything downstream.
# Kept as one tested seam (the bash counterpart of the zsh _nh_handle_response body).
_nh_compute_suggestion() {
    local buffer=$1 response=$2
    # _nh_parse_response is self-defaulting (resets all four even on a jq failure), so these
    # are declared local purely for scoping — no pre-defaulting needed.
    local text replace_start replace_end diff_ops_present
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
    # Normalize to base-10 so a zero-padded offset (e.g. "08"/"09" from a misbehaving or
    # hostile daemon) can't trip octal parsing inside the converters' `(( ))` arithmetic —
    # which fails closed but spews "value too great for base" to stderr on every keystroke in
    # the live path. Mirrors the debounce 10# guard. The ^[0-9]+$ check above guarantees a
    # non-negative digit string, so 10# here is safe (no sign/overflow surprise).
    replace_start=$(( 10#$replace_start ))
    replace_end=$(( 10#$replace_end ))
    # Protocol byte offsets -> char indices against the snapshot buffer. Fail closed if
    # either is out of range or splits a multibyte char.
    local rstart rend
    rstart=$(_nh_byte_to_char "$buffer" "$replace_start")
    rend=$(_nh_byte_to_char "$buffer" "$replace_end")
    if (( rstart < 0 || rend < 0 || rend < rstart )); then
        _nh_log "rejected: replace range not on a code-point boundary"
        return 0
    fi
    local tag
    tag=$(_nh_decide_render "$buffer" "$text" "$rstart" "$diff_ops_present")
    [[ -n "$tag" ]] || return 0
    # Append the ACCEPT payload as three more TAB fields, making the full record:
    #   <kind>\t<display>\t<bstart>\t<bend>\t<text>
    # bstart/bend are the daemon's own BYTE offsets (already base-10 normalized above), NOT
    # the char offsets fed to _nh_decide_render — accept splices in the byte domain, so it
    # wants bytes. The byte->char conversion above stays purely as the fail-closed
    # code-point-boundary guard (a mid-char offset is rejected before we ever get here).
    # _nh_decide_render's own 2-field display contract is unchanged; only THIS function emits
    # the 5-field record, and _nh_worker splits it. Safe to TAB-join: _nh_has_ctrl_char
    # already rejected any suggestion containing a literal TAB (0x09), so neither <display>
    # nor <text> can carry one.
    printf '%s\t%s\t%s\t%s' "$tag" "$replace_start" "$replace_end" "$text"
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

# ======================================================================================
# SESSION 3: async direct-paint IPC + accept-splice + key bindings (the live layer).
#
# bash has no `zle -F` fd-callback and no way to programmatically re-enter the line editor, so
# async rendering can't be driven from the foreground. Empirically (see the dev wake-spike), a
# background WORKER that writes the ghost straight to /dev/tty SURVIVES while idle, because nothing
# triggers a readline redisplay to erase it; a signal+trap paint, by contrast, gets wiped by
# readline's post-trap redisplay. So: the foreground keystroke fire-and-forgets a worker; the
# worker sleeps the debounce, queries the daemon, and (if not superseded) PAINTS the ghost then
# writes the accept payload to a `stash` FILE. A monotonic generation counter (`gen` file) is the
# cross-process staleness token; accept reads + revalidates the stash against the live buffer.
#
# KNOWN LIMITATIONS (documented, not bugs):
#  - Unbound editing keys not in our set (history Up/Down, Ctrl-R, Ctrl-K/U/W, …) don't bump the
#    generation, so an in-flight worker can paint once mid-line; the next bound key clears it.
#    Common cursor MOVES (Left/Home/End) ARE bound to clear+invalidate. Ctrl-K/U/W are left native
#    on purpose — reimplementing them in bash would break the kill-ring (Ctrl-Y yank).
#  - A stale ghost can linger one keystroke under fast typing (worker preempted between its final
#    generation check and the tty write). Bounded + self-healing; accept revalidates against the
#    LIVE buffer so a stale ghost can never be ACCEPTED. If interleave corruption is ever visible,
#    flip on the flock in _nh_tty_write (one place — see there).
#  - Bracketed paste bypasses per-char bindings (no ghost during paste — fine).
#  - Bindings install in the emacs keymap; vi-mode keymaps are untouched.
#  - Escape-to-dismiss binds bare \e (see the bindings note); a LONE Esc waits keyseq-timeout.
# ======================================================================================

# --- Per-session state dir + cross-process generation ---
# The run dir holds `gen` (generation) and `stash` (accept payload). The per-load $RANDOM NONCE
# makes re-source teardown real: a new load picks a fresh path, so any in-flight worker from a
# prior load reads `cat gen` -> ENOENT and exits. Created INSIDE the interactive guard; an unset
# _nh_run_dir (non-interactive source, e.g. the unit harness) makes every helper below a no-op.
_nh_state_init() {
    local base="${TMPDIR:-/tmp}" d pid
    # Reap THIS shell's prior-load dirs (re-source: same PID, the new dir isn't created yet).
    for d in "$base"/nighthawk-plugin-"$$"-*; do
        [[ -d "$d" && "$d" == */nighthawk-plugin-* ]] && rm -rf -- "$d"
    done
    # Opportunistic GC of crashed/HUP'd OTHER sessions whose PID is no longer alive.
    for d in "$base"/nighthawk-plugin-*; do
        [[ -d "$d" ]] || continue
        pid=${d##*/nighthawk-plugin-}; pid=${pid%%-*}
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null && continue
        [[ "$d" == */nighthawk-plugin-* ]] && rm -rf -- "$d"
    done
    # mktemp -d atomically creates a 0700 dir with an unpredictable suffix and FAILS on collision.
    # This closes the predictable-name window: `mkdir -p $$-$RANDOM` would ACCEPT a dir another
    # local user pre-created on a world-writable $TMPDIR (15-bit $RANDOM is guessable) and would
    # NOT reapply -m 700 to it — letting them read/tamper with gen/stash. The $$ stays in the
    # template so the same-shell reap + dead-PID GC above still parse the PID out of the name.
    _nh_run_dir=$(mktemp -d "$base/nighthawk-plugin-$$-XXXXXXXX" 2>/dev/null) || { _nh_run_dir=""; return 1; }
    _nh_gen=0
    printf '%s' 0 > "$_nh_run_dir/gen"
}

# Remove our run dir. GUARDED against an empty/foreign path so a bare `rm -rf "$var"` can never run
# on an unset var. Backstop for crash/HUP/KILL is the next session's GC in _nh_state_init.
_nh_cleanup() {
    [[ -n "$_nh_run_dir" && "$_nh_run_dir" == */nighthawk-plugin-* ]] && rm -rf -- "$_nh_run_dir"
}

# Bump the generation: in-process counter + a fork-free write-through to the `gen` file (plain
# `printf >`, NOT temp+mv — do NOT "fix" with mv, which adds a per-keystroke fork). The staleness
# guarantee is NOT write atomicity: a torn read CAN momentarily equal a PRIOR complete gen value
# (e.g. 9->10 flushes "1" before "0", briefly matching a still-live gen0=1 worker). It's safe only
# because any worker holding that older gen0 was debounce-cancelled many keystrokes earlier — so a
# torn value can match a worker that has already exited. INVARIANT: if worker lifetime ever grows
# past the debounce (a retry loop, a longer post-IPC window), this false-match reopens; switch to an
# atomic mv-based gen write then. The single gen mutator, so var and file can't skew. Called once
# per bound keystroke, before guards.
_nh_bump_gen() {
    [[ -n "$_nh_run_dir" ]] || return 0
    _nh_gen=$(( _nh_gen + 1 ))
    printf '%s' "$_nh_gen" > "$_nh_run_dir/gen"
}

# --- The ONLY /dev/tty sink ---
# Both the foreground clear and the worker paint route through here, so the flock escape hatch (if
# interleave corruption ever shows under fast typing) lives in ONE place: wrap the write in
#   { flock 9; printf '%s' "$1" >/dev/tty; } 9>"$_nh_run_dir/lock"
# (flock auto-creates the lockfile via the redirect — no reserved file needed). v1 ships no flock.
_nh_tty_write() {
    printf '%s' "$1" > /dev/tty 2>/dev/null
}

# --- Ghost clear ---
# UNCONDITIONAL ESC[0J (clear to end of SCREEN, so a wrapped ghost is fully erased) + drop the
# stash so a stale suggestion can never be accepted after the ghost is gone. No presence guard:
# the foreground can't know the worker's paint length, and the clear is cheap enough to always
# emit. Does NOT bump the generation (keystroke handlers bump separately).
_nh_clear_ghost() {
    _nh_tty_write "${_nh_esc}[s${_nh_esc}[0J${_nh_esc}[u"
    [[ -n "$_nh_run_dir" ]] && rm -f "$_nh_run_dir/stash"
}

# --- Daemon auto-start (best-effort, detached) ---
# Spawned in a background subshell so it never blocks the keystroke. The caller's backoff
# prevents re-spawning every keystroke when `nh` is missing or the daemon won't come up.
_nh_ensure_daemon() {
    command -v nh >/dev/null 2>&1 && ( nh start >/dev/null 2>&1 & )
}

# --- Dispatch (foreground, NON-BLOCKING — Session 3) ---
# Clear the ghost, bump the generation (a changed buffer/cursor makes any in-flight worker's
# suggestion stale, so invalidating it is correct), run the cheap foreground guards, then
# fire-and-forget ONE worker. The `( ( … ) & )` double-subshell backgrounds inside a subshell
# where job control is OFF, so no `[n] pid` notification corrupts the line. Nothing here blocks
# the keystroke. EOL invariant: READLINE_POINT (a BYTE offset) must equal the buffer's BYTE length
# (never ${#buffer}, a char count under UTF-8). A missing socket arms a 5s backoff (the present-
# but-hung case just costs one off-thread worker that eats socat -t3 — never a freeze).
_nh_dispatch() {
    local buffer=$READLINE_LINE
    _nh_clear_ghost
    _nh_bump_gen
    [[ -n "$_nh_run_dir" ]] || return 0
    [[ ${#buffer} -ge 2 ]] || return 0
    local blen_bytes
    blen_bytes=$(_nh_eol_bytes "$buffer")
    (( READLINE_POINT == blen_bytes )) || return 0
    local now=${EPOCHSECONDS:-$(date +%s)}
    (( now < _nh_backoff_until )) && return 0
    if [[ ! -S "$NIGHTHAWK_SOCKET" ]]; then
        _nh_backoff_until=$(( now + 5 ))
        _nh_ensure_daemon
        return 0
    fi
    local gen0=$_nh_gen
    ( ( _nh_worker "$gen0" "$buffer" "$blen_bytes" ) & )
}

# --- Worker (background subshell; inherits all _nh_* fns + state vars) ---
# Sleeps the debounce, double-checks the generation (debounce-cancel), queries the daemon, runs the
# pure pipeline (which enforces the control-char + range guards — the security backstop), re-checks
# the generation immediately before any screen write, then PAINTS BEFORE STASHING so accept can
# never fire on an unseen ghost: if the worker dies between paint and stash the user merely saw a
# ghost with no stash, and accept no-ops (ghost clears on the next key). Every spawn is preceded by
# _nh_bump_gen, so each worker has a unique gen0 and same-gen double-stash is unreachable.
_nh_worker() {
    local gen0=$1 buf=$2 cur=$3
    sleep "$_nh_debounce_sec"
    [[ "$(cat "$_nh_run_dir/gen" 2>/dev/null)" == "$gen0" ]] || return 0
    local req resp
    req=$(_nh_build_request "$buf" "$cur" "$PWD")
    # head -n1 closes after one line; socat then takes SIGPIPE and exits (stderr suppressed).
    resp=$(printf '%s\n' "$req" | socat -t3 - "UNIX-CONNECT:$NIGHTHAWK_SOCKET" 2>/dev/null | head -n1)
    [[ -n "$resp" ]] || return 0
    local out
    out=$(_nh_compute_suggestion "$buf" "$resp")
    [[ -n "$out" ]] || return 0
    # Post-IPC staleness AND last-chance ENOENT (teardown) check, immediately before any write.
    [[ "$(cat "$_nh_run_dir/gen" 2>/dev/null)" == "$gen0" ]] || return 0
    local kind display bstart bend text
    IFS=$'\t' read -r kind display bstart bend text <<<"$out"
    # (a) PAINT first (folds in the retired _nh_render_ghost — single tty sink). The display field's
    # load-bearing leading space (" -> text", or a suffix that starts with a space) is preserved.
    _nh_tty_write "${_nh_esc}[s${_nh_esc}[90m${display}${_nh_esc}[0m${_nh_esc}[u"
    # (b) then STASH atomically (same-dir temp + mv => rename is atomic; off-thread, fork is fine).
    printf '%s\t%s\t%s\t%s' "$gen0" "$bstart" "$bend" "$text" > "$_nh_run_dir/.stash.$BASHPID" 2>/dev/null \
        && mv -f "$_nh_run_dir/.stash.$BASHPID" "$_nh_run_dir/stash" 2>/dev/null
}

# --- Per-keystroke insert + trigger ---
# bash has no self-insert widget under `bind -x`, so each printable key is rebound to insert its
# own char then dispatch. The insert lives in a SEPARATE function under `local LC_ALL=C` so the
# byte-domain slice indexes READLINE_POINT (a byte offset) correctly around any multibyte content,
# and the C locale can't leak into the UTF-8 char math elsewhere. All bound chars are 1-byte ASCII.
_nh_insert_byte() {
    local LC_ALL=C
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}$1${READLINE_LINE:READLINE_POINT}"
    (( READLINE_POINT += ${#1} ))
}
_nh_self_insert() {
    _nh_insert_byte "$1"
    _nh_dispatch
}

# --- Backspace ---
# `bind -x` can't delegate to native backward-delete-char, so deletion is reimplemented in the CHAR
# domain so a multibyte tail (é=2B, →=3B) is removed WHOLE. The rebuild slice runs in the ambient
# UTF-8 locale; only the byte re-measure for READLINE_POINT flips to C (isolated in _nh_char_to_byte).
# Then _nh_dispatch (which clears the ghost + bumps the generation) re-queries.
_nh_bdelete_byte() {
    local LC_ALL=C
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT-1}${READLINE_LINE:READLINE_POINT}"
    (( READLINE_POINT -= 1 ))
}
_nh_backward_delete() {
    (( READLINE_POINT > 0 )) || { _nh_dispatch; return 0; }
    local pchar
    pchar=$(_nh_byte_to_char "$READLINE_LINE" "$READLINE_POINT")
    if (( pchar > 0 )); then
        READLINE_LINE="${READLINE_LINE:0:pchar-1}${READLINE_LINE:pchar}"
        READLINE_POINT=$(_nh_char_to_byte "$READLINE_LINE" $(( pchar - 1 )))
    else
        _nh_bdelete_byte
    fi
    _nh_dispatch
}

# --- Accept precondition (single source of truth) ---
# True iff a live stash exists AND the cursor is at EOL — the gate both accept-key handlers
# (_nh_forward_or_accept / _nh_tab_widget) check before delegating to _nh_accept, which then
# RE-validates everything authoritatively (and clears on any reject). Centralized here so the two
# callers can't drift in how they test stash-presence + EOL. Returns 1 (not-ready) on a no-op source
# where _nh_run_dir is unset, so the live helpers stay inert under the unit harness.
_nh_stash_ready() {
    [[ -n "$_nh_run_dir" && -f "$_nh_run_dir/stash" ]] || return 1
    local eol; eol=$(_nh_eol_bytes "$READLINE_LINE")
    (( READLINE_POINT == eol ))
}

# --- Accept (byte-domain splice, file-driven) ---
# Read the accept payload from the `stash` FILE (the worker wrote it cross-process), revalidate
# against LIVE state, then splice in the byte domain. Defenses, in order: stash must exist; its
# `sgen` must equal the live generation (else stale -> clear); range must be digits; control-char
# re-guard (the NON-NEGOTIABLE backstop against a planted-newline auto-submit / ESC hijack); EOL
# re-check (a stash can outlive an unbound cursor move); live byte-bounds re-check. Byte domain
# throughout under `local LC_ALL=C` (bstart/bend and READLINE_POINT are all byte offsets, so NO
# char<->byte conversion — the worker's pipeline already validated code-point boundaries).
_nh_accept() {
    # Re-tests stash presence (not via _nh_stash_ready) ON PURPOSE: _nh_accept is the authoritative
    # gate and must stand alone — the unit harness and any future caller invoke it directly without
    # the caller-side _nh_stash_ready pre-check. The EOL re-check below is likewise independent.
    [[ -n "$_nh_run_dir" && -f "$_nh_run_dir/stash" ]] || return 0
    local sgen bstart bend text
    IFS=$'\t' read -r sgen bstart bend text < "$_nh_run_dir/stash"
    [[ "$sgen" == "$_nh_gen" ]] || { _nh_clear_ghost; return 0; }
    [[ "$bstart" =~ ^[0-9]+$ && "$bend" =~ ^[0-9]+$ ]] || return 0
    _nh_has_ctrl_char "$text" && { _nh_clear_ghost; return 0; }
    local eol; eol=$(_nh_eol_bytes "$READLINE_LINE")
    # Clear on the off-EOL reject too (a stash can outlive an UNBOUND cursor move that didn't clear);
    # matching the stale-gen / ctrl-char branches above so no reject path can strand a painted ghost.
    (( READLINE_POINT == eol )) || { _nh_clear_ghost; return 0; }
    _nh_clear_ghost
    local LC_ALL=C
    local blen=${#READLINE_LINE}
    # Self-contained range guard: also bound bstart (not just bend) so accept never trusts the
    # cross-process worker's [bstart,bend) ordering. Today bend>=bstart is enforced upstream, but
    # re-checking here keeps the splice correct even against a hand-tampered stash.
    (( bend < bstart || bstart > blen || bend > blen )) && return 0
    local before=${READLINE_LINE:0:bstart} after=${READLINE_LINE:bend}
    READLINE_LINE="${before}${text}${after}"
    READLINE_POINT=$(( ${#before} + ${#text} ))
}

# --- RightArrow / Ctrl-F: accept at EOL, else move forward one char ---
# Presence is now stash-file existence (the in-process _nh_sug_* globals are retired). At EOL with a
# live stash -> accept; otherwise drop the ghost, invalidate in-flight workers (bump), and
# reimplement forward-char (advance one CHAR, multibyte-safe). At EOL with no stash this is a no-op.
_nh_forward_or_accept() {
    if _nh_stash_ready; then
        _nh_accept
        return 0
    fi
    _nh_clear_ghost
    _nh_bump_gen
    local cchar
    cchar=$(_nh_byte_to_char "$READLINE_LINE" "$READLINE_POINT")
    (( cchar >= 0 && cchar < ${#READLINE_LINE} )) && \
        READLINE_POINT=$(_nh_char_to_byte "$READLINE_LINE" $(( cchar + 1 )))
}

# --- Tab: accept the suggestion (OPT-IN, bash-only; bound only when _nh_tab_accept=1) ---
# Accepts a live ghost at EOL; otherwise a NO-OP. bash's `bind -x` cannot fall back to native
# readline completion (unlike zsh's `zle expand-or-complete` / PowerShell's TabCompleteNext), so
# when this is enabled and no suggestion is showing, Tab does nothing — the documented tradeoff of
# turning it on. Right arrow + Ctrl-F remain accept keys whether or not this is enabled.
_nh_tab_widget() {
    _nh_stash_ready && _nh_accept
}

# --- Bound cursor MOTIONS: clear the ghost + invalidate in-flight workers, then move ---
# Closes the "worker paints mid-line after a cursor move" regression for the common keys. PURE
# motions only (no buffer mutation, no kill-ring) so reimplementing them is trivially correct.
# Ctrl-K/U/W are NOT bound — a bash reimplementation can't populate the kill-ring, so Ctrl-Y would
# break; they stay native and fall into the documented "unbound key may linger a ghost" bucket.
_nh_cursor_left() {
    _nh_clear_ghost; _nh_bump_gen
    local cchar
    cchar=$(_nh_byte_to_char "$READLINE_LINE" "$READLINE_POINT")
    (( cchar > 0 )) && READLINE_POINT=$(_nh_char_to_byte "$READLINE_LINE" $(( cchar - 1 )))
}
_nh_cursor_home() { _nh_clear_ghost; _nh_bump_gen; READLINE_POINT=0; }
_nh_cursor_end()  { _nh_clear_ghost; _nh_bump_gen; READLINE_POINT=$(_nh_eol_bytes "$READLINE_LINE"); }

# --- Escape: dismiss the ghost (and invalidate any in-flight worker) ---
_nh_dismiss() {
    _nh_clear_ghost
    _nh_bump_gen
}

# --- Bind one printable char to insert-and-suggest ---
# Quoting is the hazard (the curated set includes " \ ` $ ' and space). Only " and \ need readline
# keyseq escaping; the ARGUMENT half is %q-quoted so the char reaches _nh_self_insert intact
# regardless of shell metacharacters.
#
# The KEYSEQ escaping uses a `case`, NOT ${seq//\\/\\\\}: as of bash 5.1 the REPLACEMENT half of a
# ${//} expansion processes backslashes, so the four-backslash replacement collapses back to a
# single \ — leaving the `\` key unbound AND printing `bind: no closing '"'` at every interactive
# startup/re-source. The case sidesteps that layer entirely (verified on bash 5.2).
_nh_bind_insert() {
    local seq q
    case $1 in
        '\') seq='\\' ;;     # readline keyseq for a literal backslash key
        '"') seq='\"' ;;     # readline keyseq for a literal double-quote key
        *)   seq=$1   ;;
    esac
    printf -v q '%q' "$1"
    bind -x "\"${seq}\": _nh_self_insert ${q}"
}

# --- Key bindings + state init (interactive shells only) ---
# Guarded so a non-interactive source (the unit harness) has zero side effects: no run dir, no
# trap, no bindings, and every live helper is a no-op on the unset _nh_run_dir. Re-sourcing is
# safe: _nh_state_init picks a fresh nonce'd dir (orphaning prior-load workers) and `bind -x`
# rebinding is idempotent. The function definitions above are OUTSIDE this guard so the harness can
# unit-test _nh_accept etc. with an injected _nh_run_dir.
if [[ $- == *i* ]] && (( BASH_VERSINFO[0] >= 4 )); then
    _nh_state_init
    # Chain (don't clobber) any pre-existing EXIT trap; idempotent on re-source. HUP/KILL/crash are
    # covered by the next session's dead-PID GC in _nh_state_init.
    _nh_prev_exit=$(trap -p EXIT)
    case "$_nh_prev_exit" in
        *_nh_cleanup*) : ;;                                   # already chained (re-source)
        "") trap '_nh_cleanup' EXIT ;;
        *)  # Wrap the prior trap in a function rather than string-splicing its body into a fresh
            # `trap` command. `trap -p` renders an embedded single quote as the '\'' idiom, escaped
            # RELATIVE TO the outer quotes; stripping those outer quotes orphans the escaping and a
            # re-quote yields `unexpected EOF looking for matching '` on exit — silently killing BOTH
            # the user's trap AND our cleanup. Instead strip only the `trap -- `/` EXIT` command
            # wrapper (body quoting left intact) and `eval` the body inside the wrapper: eval's own
            # quote-removal recovers the original command faithfully, quotes and all.
            _nh_prev_exit=${_nh_prev_exit#trap -- }
            _nh_prev_exit=${_nh_prev_exit% EXIT}
            eval "_nh_run_prev_exit() { eval ${_nh_prev_exit}; }"
            trap '_nh_cleanup; _nh_run_prev_exit' EXIT ;;
    esac
    unset _nh_prev_exit

    # Printable ASCII -> insert + dispatch. Curated set; Tab and control keys are intentionally
    # absent so native Tab-completion (and fzf/atuin/menu-complete) is left fully intact.
    for _nh_c in {a..z} {A..Z} {0..9} ' ' '-' '_' '.' '/' '\' ':' '~' '=' '+' '@' '#' '%' \
        '^' '&' '*' ',' ';' '!' '|' "'" '"' '(' ')' '[' ']' '{' '}' '<' '>' '?' '$' '`'; do
        _nh_bind_insert "$_nh_c"
    done
    unset _nh_c

    # Backspace (both common encodings) -> char-domain delete + re-dispatch.
    bind -x '"\C-?": _nh_backward_delete'
    bind -x '"\C-h": _nh_backward_delete'

    # Accept keys: RightArrow (\e[C + application-mode \eOC) and Ctrl-F. Accept at EOL, else move.
    bind -x '"\e[C": _nh_forward_or_accept'
    bind -x '"\eOC": _nh_forward_or_accept'
    bind -x '"\C-f": _nh_forward_or_accept'

    # Tab -> accept (OPT-IN, default off; `tab_accept = true` / NIGHTHAWK_TAB_ACCEPT=1). Enabling it
    # GIVES UP native Tab-completion (bind -x can't delegate to it), so it's off by default — Right
    # arrow + Ctrl-F always accept. \C-i is Tab.
    if (( _nh_tab_accept )); then
        bind -x '"\C-i": _nh_tab_widget'
    fi

    # Cursor MOTIONS -> clear ghost + invalidate in-flight workers, then move (closes the mid-line
    # paint regression). Left (\e[D/\eOD), Home (\e[H/\eOH/\e[1~/\C-a), End (\e[F/\eOF/\e[4~/\C-e).
    bind -x '"\e[D": _nh_cursor_left'
    bind -x '"\eOD": _nh_cursor_left'
    bind -x '"\e[H": _nh_cursor_home'
    bind -x '"\eOH": _nh_cursor_home'
    bind -x '"\e[1~": _nh_cursor_home'
    bind -x '"\C-a": _nh_cursor_home'
    bind -x '"\e[F": _nh_cursor_end'
    bind -x '"\eOF": _nh_cursor_end'
    bind -x '"\e[4~": _nh_cursor_end'
    bind -x '"\C-e": _nh_cursor_end'

    # Escape -> dismiss the ghost. Coexists with the \e[…/\eO… arrow sequences via readline's
    # longer-match rule (a real arrow's bytes arrive together and win); only a LONE Esc waits out
    # keyseq-timeout. Highest-risk binding — verify arrows still work in manual testing.
    bind -x '"\e": _nh_dismiss'

    # Enter -> clear the ghost, then submit. `bind -x` can't call accept-line, so this is a macro:
    # run the clear helper (bound to an obscure sequence) then emit \C-j (newline), still bound to
    # native accept-line, which submits the real READLINE_LINE. \C-j (not \C-m) so the macro can't
    # re-trigger itself. The clear now fires UNCONDITIONALLY on every Enter (even with no ghost) —
    # verify no stray artifact on submit (manual-test item).
    bind -x '"\C-x\C-g": _nh_clear_ghost'
    bind '"\C-m": "\C-x\C-g\C-j"'

    # Defensive: drop any ghost state at load (e.g. re-source while a ghost was on screen).
    _nh_clear_ghost
fi
