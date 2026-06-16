#!/usr/bin/env zsh
# nighthawk zsh plugin — inline ghost text autocomplete
#
# Install: add to ~/.zshrc:  source /path/to/nighthawk.zsh
# Requires: socat, jq

# --- Configuration ---
NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"
NIGHTHAWK_FUZZY_DISPLAY="${NIGHTHAWK_FUZZY_DISPLAY:-hint}"

# Plugin settings: the [plugin] section of config.toml, with env-var overrides
# (precedence env > file > default), mirroring the PowerShell plugin's keys and
# precedence. The default arrow differs by design — zsh keeps the Unicode "→",
# PowerShell uses ASCII "->". debounce_ms drives the async query path: it is converted
# to _nh_debounce_sec below and used to arm the debounce timer in _nh_schedule_query.
typeset -g _nh_hint_arrow="→"
typeset -g _nh_debug=0
typeset -g _nh_debounce_ms=200
typeset -g _nh_log_path="${XDG_CONFIG_HOME:-$HOME/.config}/nighthawk/plugin.log"

# Minimal hand-rolled TOML reader: walks lines, tracks the current [section], and
# extracts the three keys we care about from [plugin]. We avoid a real parser to
# keep zsh dep-free; quoted-string and bool/int regexes mirror the PowerShell side
# and naturally ignore trailing comments.
_nh_load_config() {
    emulate -L zsh
    local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/nighthawk/config.toml"
    [[ -f "$config_file" ]] || return
    local line in_plugin=0
    # `|| [[ -n "$line" ]]` processes a final line with no trailing newline, which
    # read would otherwise return non-zero on and skip.
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ '^[[:space:]]*\[([^]]+)\][[:space:]]*$' ]]; then
            [[ "${match[1]}" == "plugin" ]] && in_plugin=1 || in_plugin=0
            continue
        fi
        (( in_plugin )) || continue
        if [[ "$line" =~ '^[[:space:]]*hint_arrow[[:space:]]*=[[:space:]]*"([^"]*)"' ]]; then
            _nh_hint_arrow="${match[1]}"
        elif [[ "$line" =~ '^[[:space:]]*debounce_ms[[:space:]]*=[[:space:]]*([0-9]+)' ]]; then
            _nh_debounce_ms="${match[1]}"
        elif [[ "$line" =~ '^[[:space:]]*debug[[:space:]]*=[[:space:]]*(true|false)' ]]; then
            [[ "${match[1]}" == "true" ]] && _nh_debug=1 || _nh_debug=0
        fi
    done < "$config_file"
}
_nh_load_config

# Env vars win over config.toml.
[[ -n "$NIGHTHAWK_HINT_ARROW" ]] && _nh_hint_arrow="$NIGHTHAWK_HINT_ARROW"
[[ -n "$NIGHTHAWK_DEBOUNCE_MS" ]] && _nh_debounce_ms="$NIGHTHAWK_DEBOUNCE_MS"
if [[ -n "$NIGHTHAWK_DEBUG" ]]; then
    [[ "$NIGHTHAWK_DEBUG" == "1" ]] && _nh_debug=1 || _nh_debug=0
fi

# Validate debounce_ms before it ever reaches arithmetic. The config regex above only accepts
# digits, but the env override is unguarded — a stray NIGHTHAWK_DEBOUNCE_MS=foo would otherwise
# throw "bad math expression" from inside the keystroke path when we divide. Clamp to the default.
# (<-> is zsh's digit glob.)
[[ "$_nh_debounce_ms" == <-> ]] || _nh_debounce_ms=200
# Debounce interval in seconds for the `sleep`-based timer. Float; GNU/BSD sleep accept it, the
# same assumption the existing `sleep 0.2` auto-start path already makes.
typeset -gF _nh_debounce_sec=$(( _nh_debounce_ms / 1000.0 ))

# --- Diagnostic logging ---
# No-op unless debug is on. Millisecond timestamps via GNU date's %N (present on
# Linux/WSL); harmless cosmetic degradation elsewhere.
_nh_log() {
    (( _nh_debug )) || return
    print -r -- "$(date '+%H:%M:%S.%3N' 2>/dev/null) $1" >> "$_nh_log_path" 2>/dev/null
}

# True if $1 contains a control char (0x01-0x1f or 0x7f). Single source of truth for
# the fail-closed rejection of daemon suggestions before they reach BUFFER. Floor is
# 0x01: a literal NUL can't survive zsh command substitution, so it's unreachable.
_nh_has_ctrl_char() { [[ "$1" == *[$'\x01'-$'\x1f\x7f']* ]] }

# --- Byte offset <-> char index conversion ---
# The daemon speaks UTF-8 BYTE offsets (replace_start/replace_end and the request
# cursor); zsh string subscripts (${BUFFER[1,$n]}) and $CURSOR are indexed in the
# CURRENT LOCALE's units — characters under a UTF-8 locale, raw bytes under C. These
# helpers bridge the two. Per-char byte width comes from `LC_ALL=C ${#ch}`, scoped in an
# anonymous function so the locale override can't leak into the rest of the call. That
# primitive is correct in BOTH locales: under UTF-8 a char reports its true byte length;
# under C every unit is already one byte, so both conversions collapse to the identity
# the byte-indexed subscripts want. This is the zsh counterpart of nighthawk.ps1's
# $byteToChar — minus its surrogate handling, since a zsh char is a whole scalar value
# (an emoji is one char, not a UTF-16 pair).

# Byte offset -> char index (count of leading subscript units). Fail-closed: returns -1
# for a negative offset, one past the end, or one landing inside a multibyte sequence.
_nh_byte_to_char() {
    emulate -L zsh
    local s=$1 boff=$2
    (( boff < 0 )) && { print -- -1; return }
    (( boff == 0 )) && { print -- 0; return }
    local n=${#s} c acc=0 w
    for (( c = 1; c <= n; c++ )); do
        () { local LC_ALL=C; w=${#1} } "${s[c]}"
        (( acc += w ))
        (( acc == boff )) && { print -- $c; return }   # exact code-point boundary
        (( acc > boff ))  && { print -- -1; return }    # offset split a multibyte char
    done
    print -- -1   # offset past the last byte
}

# Char index (count of leading units) -> byte offset. Clamps an over-long index to the
# string length; its only caller passes $CURSOR, which _nh_pre_redraw has already pinned to
# ${#BUFFER} (it bails unless CURSOR == ${#BUFFER}), so the clamp is belt-and-suspenders.
_nh_char_to_byte() {
    emulate -L zsh
    local s=$1 cidx=$2
    (( cidx <= 0 )) && { print -- 0; return }
    (( cidx > ${#s} )) && cidx=${#s}
    local out
    () { local LC_ALL=C; out=${#1} } "${s[1,cidx]}"
    print -- $out
}

# --- State ---
# Re-source teardown. zsh keeps `zle -F` fd registrations AND open fds across a re-source, so a
# prior load may have left a debounce/response watcher live; left alone it fires forever on its
# sleep-EOF into stale handlers and leaks the fd. Tear them down using the PREVIOUS load's saved
# fd numbers before the typesets below reset the vars. (Analogue of nighthawk.ps1's
# subscriber/timer/pool teardown at the top of its re-source path.) Unregister before close.
() {
    emulate -L zsh
    local fd
    for fd in "$_nh_debounce_fd" "$_nh_resp_fd"; do
        [[ -n "$fd" && "$fd" != 0 ]] || continue
        zle -F "$fd" 2>/dev/null
        exec {fd}<&- 2>/dev/null
    done
}

typeset -g _nh_suggestion=""
# _nh_replace_start/_end hold CHAR indices (converted from the daemon's UTF-8 byte
# offsets in _nh_handle_response), so the ${BUFFER[...]} subscripts in _nh_accept /
# _nh_render_diff index correctly under a multibyte locale.
typeset -g _nh_replace_start=""
typeset -g _nh_replace_end=""
typeset -g _nh_last_buffer=""
typeset -g _nh_has_highlight=0
typeset -g _nh_diff_ops=""
typeset -g _nh_original_buffer=""
typeset -g _nh_original_cursor=""
typeset -g _nh_backoff_until=0
# Async IPC state (see the "Daemon communication (async)" section below).
typeset -g _nh_debounce_fd=0       # fd of the in-flight debounce `sleep` timer (0 = none)
typeset -g _nh_resp_fd=0           # fd of the in-flight socat response stream (0 = none)
typeset -g _nh_gen=0               # monotonic generation, bumped on every cancel / new query
typeset -g _nh_dispatch_gen=0      # generation captured when the current request was dispatched
typeset -g _nh_inflight_buffer=""  # $BUFFER snapshot the in-flight request is about
typeset -g _nh_inflight_cursor=""  # $CURSOR snapshot (char domain) at dispatch time
typeset -g _nh_resp_accum=""       # partial-read accumulator for the response line
typeset -g _nh_pending_response="" # complete reply line, handed from fd handler to render widget

# --- Dependency check ---
if ! command -v socat &>/dev/null; then
    echo "nighthawk: socat not found, install with: apt install socat" >&2
    return 1
fi
if ! command -v jq &>/dev/null; then
    echo "nighthawk: jq not found, install with: apt install jq" >&2
    return 1
fi

# zsh/system provides `sysread`, the non-blocking fd drain used by the async response handler.
# It's a standard built-in module that ships with zsh, so this is not a new external dependency.
zmodload zsh/system 2>/dev/null

# --- Ghost text rendering via POSTDISPLAY ---
_nh_render_ghost() {
    local ghost="$1"
    if [[ -n "$ghost" ]]; then
        POSTDISPLAY="$ghost"
        region_highlight+=("${#BUFFER} $((${#BUFFER} + ${#ghost})) fg=8")
        _nh_has_highlight=1
    fi
}

# --- Inline diff rendering for fuzzy matches ---
# Temporarily replaces the mistyped token in BUFFER with the diff text
# (keeps + deletes + inserts interleaved), then uses region_highlight
# to color each character: red+bold for deletes, gray for inserts.
# Original buffer is saved and restored on clear/accept.
_nh_render_diff() {
    local diff_ops="$1"
    local token_start="$2"
    local replace_end="$3"

    # Save original buffer so we can restore it later
    _nh_original_buffer="$BUFFER"
    _nh_original_cursor="$CURSOR"

    # Build the diff-rendered token and track highlight regions
    local new_token=""
    local -a diff_highlights=()
    local pos=$token_start
    local last_typed_pos=$token_start  # tracks end of user-typed chars

    local entry op ch
    for entry in ${(s: :)diff_ops}; do
        op="${entry[1]}"
        ch="${entry[3,-1]}"
        case "$op" in
            k)  new_token+="$ch"; pos=$((pos + 1))
                last_typed_pos=$pos ;;
            d)  new_token+="$ch"
                diff_highlights+=("$pos $((pos + 1)) fg=red,bold")
                pos=$((pos + 1))
                last_typed_pos=$pos ;;
            i)  new_token+="$ch"
                diff_highlights+=("$pos $((pos + 1)) fg=8")
                pos=$((pos + 1)) ;;
        esac
    done

    # Replace token in BUFFER: before + diff_token + after
    # Zsh strings are 1-indexed; token_start/replace_end are 0-indexed CHAR offsets
    # (converted from the daemon's byte offsets in _nh_handle_response before this is called).
    local before="${_nh_original_buffer[1,$token_start]}"
    local after="${_nh_original_buffer[$((replace_end + 1)),-1]}"
    BUFFER="${before}${new_token}${after}"
    # Cursor after last Keep/Delete (user-typed chars), not trailing Inserts.
    # This way Insert chars after the cursor look like ghost text.
    CURSOR=$last_typed_pos

    # Update last_buffer so pre_redraw doesn't re-trigger on our modification
    _nh_last_buffer="$BUFFER"

    # Apply highlights
    for hl in "${diff_highlights[@]}"; do
        region_highlight+=("$hl")
    done
    _nh_has_highlight=${#diff_highlights[@]}
}

# --- Hint rendering for fuzzy matches ---
# Shows " -> suggestion" as gray POSTDISPLAY text.
# Does NOT modify BUFFER, so no save/restore dance needed.
_nh_render_hint() {
    local suggestion="$1"
    if [[ -n "$suggestion" ]]; then
        POSTDISPLAY=" $_nh_hint_arrow $suggestion"
        region_highlight+=("${#BUFFER} $((${#BUFFER} + ${#POSTDISPLAY})) fg=8")
        _nh_has_highlight=1
    fi
}

# --- Restore original buffer before user edits ---
# When diff rendering has modified BUFFER, we must restore the original
# before any editing operation so the keystroke applies to the right text.
_nh_restore_before_edit() {
    if [[ -n "$_nh_original_buffer" ]]; then
        BUFFER="$_nh_original_buffer"
        CURSOR=${#BUFFER}  # end of original text
        _nh_original_buffer=""
        _nh_original_cursor=""
        region_highlight=()
        _nh_has_highlight=0
        _nh_diff_ops=""
        _nh_suggestion=""
        _nh_replace_start=""
        _nh_replace_end=""
        unset POSTDISPLAY
        _nh_last_buffer="$BUFFER"
    fi
}

_nh_self_insert() {
    _nh_restore_before_edit
    zle .self-insert
}
zle -N self-insert _nh_self_insert

_nh_backward_delete() {
    _nh_restore_before_edit
    zle .backward-delete-char
}
zle -N backward-delete-char _nh_backward_delete

_nh_backward_kill_word() {
    _nh_restore_before_edit
    zle .backward-kill-word
}
zle -N backward-kill-word _nh_backward_kill_word

_nh_clear_ghost() {
    # Cancel any pending debounce timer / in-flight request so a now-stale reply can't paint a
    # phantom ghost after the buffer moved on. This is the zsh analogue of nighthawk.ps1's
    # _nh_clear_ghost stopping the timer + bumping generation. Also covers the Escape path, which
    # routes through here. (Re-armed by the next keystroke's _nh_schedule_query.)
    _nh_cancel_inflight

    # Clear any ghost we rendered. POSTDISPLAY and region_highlight are ZLE-managed:
    # unsetting them and letting ZLE repaint clears the ghost — including wrapped
    # lines, whose row count ZLE already tracks. Do NOT emit raw clear escapes here.
    # This runs inside zle-line-pre-redraw, before ZLE repaints; a manual \e[0J
    # erases from the stale cursor and desyncs ZLE's display bookkeeping, which
    # corrupts the very ghost we then paint (the classic "forward shows nothing,
    # backspace shows one char" glitch).
    unset POSTDISPLAY

    # Remove the highlight entries we appended (zsh-native brace range — no subprocess).
    if (( _nh_has_highlight )); then
        local i
        for i in {1..$_nh_has_highlight}; do
            region_highlight[-1]=()
        done
        _nh_has_highlight=0
    fi

    # Restore original buffer if diff rendering modified it
    if [[ -n "$_nh_original_buffer" ]]; then
        BUFFER="$_nh_original_buffer"
        CURSOR="$_nh_original_cursor"
        _nh_original_buffer=""
        _nh_original_cursor=""
    fi

    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
    _nh_diff_ops=""
}

# --- Auto-start ---
_nh_ensure_daemon() {
    # Quick check: does the socket exist?
    [[ -S "$NIGHTHAWK_SOCKET" ]] && return 0

    # Try to start the daemon (one attempt, non-blocking)
    if command -v nh &>/dev/null; then
        nh start &>/dev/null
    elif command -v nighthawk-daemon &>/dev/null; then
        nighthawk-daemon &>/dev/null &
        disown
        sleep 0.2
    fi

    return 0
}

# --- Daemon communication (async) ---
# Split across the keystroke and the eventual reply so IPC never blocks the input loop
# (CLAUDE.md: "Never block the input loop in shell plugins"). zsh has no threads, so the async
# seam is the socket fd: `zle -F <fd> <handler>` makes ZLE call us back when a descriptor is
# readable. Flow per query:
#   keystroke -> _nh_schedule_query   arm a debounce timer (a `sleep` whose EOF fires us)
#             -> _nh_debounce_fire     timer elapsed -> actually send the request
#             -> _nh_dispatch          spawn socat, register the response fd
#             -> _nh_on_response        fd readable -> drain (non-blocking), staleness-gate
#             -> _nh_handle_response    parse + validate + render (the old synchronous body)
# This mirrors nighthawk.ps1's debounce-timer -> runspace-worker. PowerShell needs a synchronized
# hashtable + generation counter to coordinate REAL threads; our callbacks run on the same thread
# as keystrokes, so a buffer snapshot is itself a sound staleness signal and the generation
# counter is kept only as defense-in-depth.

# Tear down a pending debounce timer and/or in-flight request, and bump the generation so any
# reply still in flight is treated as stale. Idempotent — every teardown path calls it. Unregister
# BEFORE close (a closed fd number may already be recycled, so a late unregister could hit the
# wrong watcher), and null the handle after so a double-cancel can't close a descriptor zsh has
# since handed to something else.
_nh_cancel_inflight() {
    emulate -L zsh
    (( _nh_gen++ ))
    local fd
    if [[ -n "$_nh_debounce_fd" && "$_nh_debounce_fd" != 0 ]]; then
        fd=$_nh_debounce_fd
        zle -F "$fd" 2>/dev/null
        exec {fd}<&- 2>/dev/null
        _nh_debounce_fd=0
    fi
    if [[ -n "$_nh_resp_fd" && "$_nh_resp_fd" != 0 ]]; then
        fd=$_nh_resp_fd
        zle -F "$fd" 2>/dev/null
        exec {fd}<&- 2>/dev/null
        _nh_resp_fd=0
    fi
    _nh_resp_accum=""
}

# A reply is fresh iff nothing superseded the request since dispatch. The generation counter is the
# whole signal: every cancel / new query bumps _nh_gen (via _nh_cancel_inflight) and re-stamps
# _nh_dispatch_gen, so a reply is current exactly when the two are still equal. Because these
# callbacks run on the SAME thread as keystrokes (they can't interleave), the generation can't drift
# under us mid-check — there's no ABA race to defend against. We deliberately do NOT compare against
# live $BUFFER/$CURSOR here: inside a `zle -F` fd-handler callback those special parameters are NOT
# bound to the line editor (they read back empty), so a buffer/cursor compare would reject every
# reply. The dispatch snapshot ($_nh_inflight_buffer/_cursor) is what the render path uses instead.
# Factored out so the async path is unit-testable without a live fd.
_nh_reply_is_fresh() {
    (( _nh_gen == _nh_dispatch_gen ))
}

# Keystroke entry point: arm the debounce timer.
_nh_schedule_query() {
    emulate -L zsh
    # Back off after a connection failure so a dead daemon doesn't arm a timer every keystroke.
    (( EPOCHSECONDS < _nh_backoff_until )) && return

    _nh_ensure_daemon

    # Cancel any prior timer/request (also bumps the generation), then snapshot the buffer this
    # query is about. The snapshot is both the staleness key and the exact string the daemon's
    # byte offsets are resolved against in _nh_handle_response.
    _nh_cancel_inflight
    _nh_inflight_buffer="$BUFFER"
    _nh_inflight_cursor="$CURSOR"
    _nh_dispatch_gen=$_nh_gen

    # The debounce timer is a `sleep` subprocess; its EOF (process exit) makes the fd readable and
    # fires _nh_debounce_fire. If the user types again first, _nh_cancel_inflight closes this fd
    # before the sleep ends so the request is never sent — coalescing keystrokes is the whole point
    # of debounce, and keeping the sleep SEPARATE from socat is what lets us cancel before paying
    # for a daemon round-trip (vs. folding `sleep; socat` into one child, which would query on every
    # keystroke unless we tracked and killed its PID).
    local fd
    exec {fd}< <(sleep $_nh_debounce_sec) || return
    _nh_debounce_fd=$fd
    zle -F "$fd" _nh_debounce_fire
}

# Debounce elapsed: disarm the timer fd and send the request.
_nh_debounce_fire() {
    emulate -L zsh
    local fd=$1
    zle -F "$fd" 2>/dev/null
    exec {fd}<&- 2>/dev/null
    _nh_debounce_fd=0
    _nh_dispatch
}

# Build the request from the snapshot and spawn the non-blocking socat read.
_nh_dispatch() {
    emulate -L zsh
    local buffer="$_nh_inflight_buffer"
    local cursor="$_nh_inflight_cursor"

    # The protocol cursor is a UTF-8 byte offset, but the snapshot $cursor is a char index —
    # convert before sending, mirroring nighthawk.ps1's GetByteCount. (Sending the raw char cursor
    # would also make the daemon slice &input[..cursor] at a non-boundary byte on multibyte input.)
    local cursor_bytes=$(_nh_char_to_byte "$buffer" "$cursor")

    # Escape for JSON: backslashes then double quotes
    local escaped_buffer="${buffer//\\/\\\\}"
    escaped_buffer="${escaped_buffer//\"/\\\"}"
    local escaped_cwd="${PWD//\\/\\\\}"
    escaped_cwd="${escaped_cwd//\"/\\\"}"

    local json="{\"input\":\"${escaped_buffer}\",\"cursor\":${cursor_bytes},\"cwd\":\"${escaped_cwd}\",\"shell\":\"zsh\"}"

    _nh_log "dispatch: buffer='$buffer' cursor=$cursor gen=$_nh_dispatch_gen"

    # socat writes the daemon's reply to this fd and exits; ZLE calls _nh_on_response when it's
    # readable. -t3 keeps socat's inactivity timeout above the cloud tier's 2000ms budget (+slack)
    # so a slow-but-valid LLM reply isn't cut off and mis-read as a dead daemon — the zsh
    # counterpart of nighthawk.ps1's 2250ms read timeout.
    local fd
    exec {fd}< <(print -r -- "$json" | socat -t3 - UNIX-CONNECT:"$NIGHTHAWK_SOCKET" 2>/dev/null) || return
    _nh_resp_fd=$fd
    _nh_resp_accum=""
    zle -F "$fd" _nh_on_response
}

# Response fd readable: drain without blocking, gate on freshness, hand off to render.
_nh_on_response() {
    emulate -L zsh
    local fd=$1 reason=$2 chunk

    # Drain everything available now. `sysread -t 0` returns 0 on bytes, 4 on would-block (no more
    # yet — stay registered for the next callback), 5/other on EOF/error. The terminating status
    # MUST be captured INSIDE the loop: a zsh `while` exits with its body's status (here the
    # successful `+=` append => 0), so reading $? after the loop would always see 0 and we'd treat a
    # mid-stream partial as a complete reply and truncate multi-chunk responses. Likewise the var is
    # `sr_status`, never `status` — `status` is a read-only alias for $? in zsh and `local status`
    # would abort this handler on every reply.
    local sr_status=4
    while :; do
        sysread -i "$fd" -t 0 chunk 2>/dev/null
        sr_status=$?
        (( sr_status == 0 )) || break
        _nh_resp_accum+="$chunk"
    done

    # Finished iff a full line is buffered, OR the stream ended (sysread EOF/error => status != 4,
    # or ZLE reported the fd hung up via a non-empty reason). Until then, wait for the next callback.
    local done=0
    [[ "$_nh_resp_accum" == *$'\n'* ]] && done=1
    (( sr_status != 4 )) && done=1
    [[ -n "$reason" ]] && done=1
    (( done )) || return

    # Tear down the fd up front so every early return in _nh_handle_response below is leak-free.
    zle -F "$fd" 2>/dev/null
    exec {fd}<&- 2>/dev/null
    _nh_resp_fd=0

    local response="${_nh_resp_accum%%$'\n'*}"   # first complete line only
    _nh_resp_accum=""

    if [[ -z "$response" ]]; then
        _nh_log "no response, backing off 5s"
        _nh_backoff_until=$(( EPOCHSECONDS + 5 ))
        return
    fi

    if ! _nh_reply_is_fresh; then
        _nh_log "stale reply dropped (gen $_nh_dispatch_gen vs $_nh_gen)"
        return
    fi

    # We CANNOT render from here. A `zle -F` fd-handler runs OUTSIDE the line-editor widget context:
    # $BUFFER/$CURSOR/$POSTDISPLAY/region_highlight are not bound to the live editor ($BUFFER reads
    # back empty), and a direct `zle -R` from here paints nothing. Stash the reply and bounce into a
    # real widget — `zle <widget>` re-enters proper editor context where those parameters ARE live
    # and the display actually updates. (Verified empirically; this is the crux of the async design.)
    _nh_pending_response="$response"
    zle _nh_apply_response
    zle -R
}

# Real ZLE widget that performs the render. Unlike _nh_on_response (an fd handler), this runs in
# editor context, so $BUFFER/$CURSOR/$POSTDISPLAY are live and the render helpers paint correctly.
# Invoked via `zle _nh_apply_response` from the fd handler once a complete, fresh reply is buffered.
_nh_apply_response() {
    emulate -L zsh
    _nh_handle_response "$_nh_pending_response"
    _nh_pending_response=""
}
zle -N _nh_apply_response

# Parse + validate + render the daemon's reply against the dispatch snapshot. This is the parse +
# render body that was synchronous before the async rewrite, now retargeted to the snapshot
# ($_nh_inflight_buffer/_cursor) instead of live $BUFFER/$CURSOR. Kept as its own function so the
# async path can be unit-tested by calling it with a canned response.
_nh_handle_response() {
    emulate -L zsh
    local response="$1"
    local buffer="$_nh_inflight_buffer"
    local cursor="$_nh_inflight_cursor"

    # Parse first suggestion (text, replace range, and diff_ops if present)
    local text replace_start replace_end diff_ops_str
    eval $(echo "$response" | jq -r '
        if (.suggestions | length) > 0 then
            "text=" + (.suggestions[0].text | @sh) +
            " replace_start=" + ((.suggestions[0].replace_start | tostring) | @sh) +
            " replace_end=" + ((.suggestions[0].replace_end | tostring) | @sh) +
            " diff_ops_str=" + ((.suggestions[0].diff_ops // null) | if . then [.[] | .op[0:1] + ":" + .ch] | join(" ") | @sh else ("" | @sh) end)
        else
            "text='"''"'"
        end
    ' 2>/dev/null)

    if [[ -n "$text" ]]; then
        # Reject any suggestion carrying a control char (0x01-0x1f or 0x7f). An
        # embedded newline auto-submits on accept (single-keystroke command
        # execution if a model emits `rm -rf $HOME\n`); an embedded ESC can hijack
        # the terminal during render. Shell commands never legitimately contain
        # control chars, so fail closed rather than strip. This $text guard mirrors
        # the PowerShell plugin's worker-side check.
        if _nh_has_ctrl_char "$text"; then
            _nh_log "rejected: control char in suggestion"
            return
        fi
        # Same guard for diff_ops — no PowerShell counterpart, because that plugin
        # renders fuzzy matches as a hint and never writes per-op bytes into the
        # buffer. Here inline-diff rendering writes the per-op `ch` bytes (not $text)
        # straight into BUFFER, so a clean $text with a tainted diff char would slip
        # the check above. Reject before any state is published so Tab can't accept
        # a phantom.
        if [[ -n "$diff_ops_str" ]] && _nh_has_ctrl_char "$diff_ops_str"; then
            _nh_log "rejected: control char in diff_ops"
            return
        fi

        # replace_start/end are interpolated into the eval above; @sh quotes them, but
        # still validate they're plain non-negative integers before any arithmetic — this
        # rejects a non-numeric jq result (e.g. "null" from a malformed reply). <-> is
        # zsh's digit glob.
        [[ "$replace_start" == <-> && "$replace_end" == <-> ]] || return

        # Protocol byte offsets -> char indices against $buffer (the exact snapshot sent
        # in the request). Fail closed — no ghost, never corrupt the buffer — if either is
        # out of range or lands inside a multibyte char; that can only be a daemon bug, so
        # log it rather than silently doing nothing. From here down these locals are
        # CHAR-domain, so the prefix math and every ${BUFFER[...]} subscript (including the
        # _nh_render_diff call below) index correctly under a multibyte locale.
        replace_start=$(_nh_byte_to_char "$buffer" "$replace_start")
        replace_end=$(_nh_byte_to_char "$buffer" "$replace_end")
        if (( replace_start < 0 || replace_end < 0 || replace_end < replace_start )); then
            _nh_log "rejected: replace range not on a code-point boundary"
            return
        fi

        _nh_suggestion="$text"
        _nh_replace_start="$replace_start"
        _nh_replace_end="$replace_end"

        if [[ -n "$diff_ops_str" ]]; then
            # Fuzzy match: render based on display mode
            if [[ "$NIGHTHAWK_FUZZY_DISPLAY" == "hint" ]]; then
                _nh_render_hint "$text"
            else
                _nh_diff_ops="$diff_ops_str"
                _nh_render_diff "$diff_ops_str" "$replace_start" "$replace_end"
            fi
        else
            # Check if this is a true prefix match or a replacement
            local already_typed_len=$(( cursor - replace_start ))
            if (( already_typed_len >= 0 && already_typed_len < ${#text} )); then
                local typed_part="${buffer:$replace_start:$already_typed_len}"
                if [[ "${text:0:$already_typed_len}" == "$typed_part" ]]; then
                    # True prefix match: show suffix as ghost text
                    local ghost="${text:$already_typed_len}"
                    _nh_render_ghost "$ghost"
                else
                    # Replacement changes typed text: show hint instead
                    _nh_render_hint "$text"
                fi
            fi
        fi
    fi
}

# --- ZLE hooks ---

# Save existing hook if any so we can chain to it — but NOT if it's already ours.
# On a re-source, zle-line-pre-redraw is already _nh_pre_redraw; aliasing it as
# _nh_orig_pre_redraw would make _nh_pre_redraw call itself and recurse on every
# redraw. Re-check the bound widget's definition and skip when it points at us.
if zle -l zle-line-pre-redraw && [[ "$(zle -lL zle-line-pre-redraw 2>/dev/null)" != *_nh_pre_redraw* ]]; then
    zle -A zle-line-pre-redraw _nh_orig_pre_redraw
fi

_nh_pre_redraw() {
    # Chain to original hook
    (( $+functions[_nh_orig_pre_redraw] )) && _nh_orig_pre_redraw

    # Only act if buffer changed
    [[ "$BUFFER" == "$_nh_last_buffer" ]] && return
    _nh_last_buffer="$BUFFER"

    # Clear previous ghost text
    _nh_clear_ghost

    # Only suggest when cursor is at end of line
    (( CURSOR != ${#BUFFER} )) && return

    # Need at least 2 chars
    (( ${#BUFFER} < 2 )) && return

    # Arm the debounce timer; the actual IPC happens off the keystroke thread (see _nh_schedule_query).
    _nh_schedule_query
}

zle -N zle-line-pre-redraw _nh_pre_redraw

# --- Accept suggestion ---
_nh_accept() {
    # Cancel any pending debounce/in-flight request so a reply arriving after we accept can't
    # repaint a ghost over the committed line (this path doesn't route through _nh_clear_ghost).
    _nh_cancel_inflight
    if [[ -n "$_nh_suggestion" && "$_nh_replace_start" != "" && "$_nh_replace_end" != "" ]]; then
        local suggestion="$_nh_suggestion"
        local rstart="$_nh_replace_start"
        local rend="$_nh_replace_end"
        _nh_log "accept: '$suggestion' [$rstart,$rend)"

        # If diff rendering modified BUFFER, restore original first
        # so replace_start/end offsets are correct
        if [[ -n "$_nh_original_buffer" ]]; then
            BUFFER="$_nh_original_buffer"
            _nh_original_buffer=""
            _nh_original_cursor=""
        fi

        # Clear ghost/highlight state
        unset POSTDISPLAY
        region_highlight=()
        _nh_has_highlight=0
        _nh_suggestion=""
        _nh_diff_ops=""

        # Defensive bounds check. rstart/rend are char offsets captured at query time
        # against the original buffer, which we just restored above, so they can't drift in
        # today's synchronous path (any edit clears them via _nh_restore_before_edit). But
        # an out-of-range zsh subscript fails SILENTLY (yields empty rather than erroring),
        # so guard explicitly — this is also the seam where async IPC will need it.
        if (( rstart < 0 || rend < rstart || rend > ${#BUFFER} )); then
            _nh_log "accept: stale/out-of-range range [$rstart,$rend) for buffer len ${#BUFFER}"
            _nh_replace_start=""
            _nh_replace_end=""
            _nh_last_buffer="$BUFFER"
            return
        fi

        # Replace the token: BUFFER[0..rstart] + suggestion + BUFFER[rend..]
        # Zsh strings are 1-indexed
        local before="${BUFFER[1,$rstart]}"
        local after="${BUFFER[$((rend + 1)),-1]}"
        BUFFER="${before}${suggestion}${after}"
        CURSOR=${#BUFFER}

        _nh_replace_start=""
        _nh_replace_end=""
        _nh_last_buffer="$BUFFER"
        zle redisplay
    else
        # No suggestion — fall through to default Tab
        zle expand-or-complete
    fi
}

zle -N _nh_accept
bindkey '^I' _nh_accept

# --- Clean up on line accept (Enter) ---
_nh_line_finish() {
    # Cancel any pending debounce/in-flight request BEFORE accept-line, so a reply that lands
    # during the transition can't paint a ghost fragment onto the next prompt. Closing the fd
    # here means a queued callback fires on a closed descriptor (no-op) and the empty next-prompt
    # buffer would fail the staleness gate anyway — belt and suspenders.
    _nh_cancel_inflight

    # Restore original buffer if diff rendering modified it,
    # so the shell executes what the user actually typed
    if [[ -n "$_nh_original_buffer" ]]; then
        BUFFER="$_nh_original_buffer"
        _nh_original_buffer=""
        _nh_original_cursor=""
    fi

    unset POSTDISPLAY
    region_highlight=()
    _nh_has_highlight=0
    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
    _nh_diff_ops=""
    _nh_last_buffer="$BUFFER"
    zle accept-line
}

zle -N _nh_line_finish
bindkey '^M' _nh_line_finish

# --- Accept on RightArrow at end of line ---
# Override the forward-char widget rather than binding a raw escape sequence, so
# every key mapped to forward-char works regardless of terminal/keypad mode. When
# a suggestion is showing and the cursor is at the end of the buffer, RightArrow
# accepts it (matching the PowerShell plugin); otherwise it moves the cursor as
# usual (restoring any diff-modified buffer first, like the other edit widgets).
_nh_forward_char() {
    # Accept when a suggestion is live. In hint/ghost mode the cursor sits at the
    # buffer end; in inline-diff mode _nh_render_diff parks it before the trailing
    # inserts (so $CURSOR != ${#BUFFER}) but leaves _nh_original_buffer set — treat
    # either as "ghost present, accept it". Only a genuinely-absent suggestion
    # falls through to a normal cursor move.
    if [[ -n "$_nh_suggestion" ]] && { [[ -n "$_nh_original_buffer" ]] || (( CURSOR == ${#BUFFER} )); }; then
        _nh_accept
    else
        _nh_restore_before_edit
        zle .forward-char
    fi
}
zle -N forward-char _nh_forward_char

# --- Escape to dismiss the ghost ---
# Binding bare ESC is safe: zsh keeps longer ESC-prefixed bindings (arrows, Alt-*)
# and only fires this widget for a lone Escape after KEYTIMEOUT. When a ghost is
# showing, Escape clears it. We must not swallow the key's normal meaning: in a vi
# keymap, Escape ALWAYS enters command mode (a vi user expects that even while a
# ghost is up), so clear the ghost AND switch mode in the same keystroke rather
# than making them press it twice. In emacs (where bare Escape is only a prefix)
# there's nothing to fall through to. NOTE: this is detected once at source time;
# switching to `bindkey -v` afterward isn't picked up until the plugin is re-sourced.
typeset -g _nh_vi_mode=0
[[ "$(bindkey -lL main 2>/dev/null)" == *vi* ]] && _nh_vi_mode=1

_nh_escape() {
    if (( _nh_has_highlight )) || [[ -n "$_nh_suggestion" ]]; then
        _nh_clear_ghost
        zle redisplay
    fi
    (( _nh_vi_mode )) && zle .vi-cmd-mode
}
zle -N _nh_escape
bindkey '^[' _nh_escape
