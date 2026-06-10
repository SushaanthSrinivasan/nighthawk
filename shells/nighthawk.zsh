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
# PowerShell uses ASCII "->". debounce_ms is parsed but not yet consumed: the zsh
# query path is still synchronous, so it will be wired when async IPC lands.
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
typeset -g _nh_suggestion=""
# _nh_replace_start/_end hold CHAR indices (converted from the daemon's UTF-8 byte
# offsets in _nh_query), so the ${BUFFER[...]} subscripts in _nh_accept / _nh_render_diff
# index correctly under a multibyte locale.
typeset -g _nh_replace_start=""
typeset -g _nh_replace_end=""
typeset -g _nh_last_buffer=""
typeset -g _nh_has_highlight=0
typeset -g _nh_diff_ops=""
typeset -g _nh_original_buffer=""
typeset -g _nh_original_cursor=""
typeset -g _nh_backoff_until=0

# --- Dependency check ---
if ! command -v socat &>/dev/null; then
    echo "nighthawk: socat not found, install with: apt install socat" >&2
    return 1
fi
if ! command -v jq &>/dev/null; then
    echo "nighthawk: jq not found, install with: apt install jq" >&2
    return 1
fi

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
    # (converted from the daemon's byte offsets in _nh_query before this is called).
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

# --- Daemon communication ---
_nh_query() {
    # Back off for 5s after connection failure so dead daemon doesn't block every keystroke
    local now=$EPOCHSECONDS
    if (( now < _nh_backoff_until )); then
        return
    fi

    _nh_ensure_daemon

    local buffer="$1"
    local cursor="$2"

    # The protocol cursor is a UTF-8 byte offset, but $CURSOR (passed in as $2) is a char
    # index — convert before sending, mirroring nighthawk.ps1's GetByteCount. The local
    # $cursor stays char-domain for the prefix-ghost math below. (Sending the raw char
    # cursor would also make the daemon slice &input[..cursor] at a non-boundary byte on
    # multibyte input.)
    local cursor_bytes=$(_nh_char_to_byte "$buffer" "$cursor")

    # Escape for JSON: backslashes then double quotes
    local escaped_buffer="${buffer//\\/\\\\}"
    escaped_buffer="${escaped_buffer//\"/\\\"}"
    local escaped_cwd="${PWD//\\/\\\\}"
    escaped_cwd="${escaped_cwd//\"/\\\"}"

    local json="{\"input\":\"${escaped_buffer}\",\"cursor\":${cursor_bytes},\"cwd\":\"${escaped_cwd}\",\"shell\":\"zsh\"}"

    _nh_log "query: buffer='$buffer' cursor=$cursor"

    local response
    response=$(echo "$json" | socat -t1 - UNIX-CONNECT:"$NIGHTHAWK_SOCKET" 2>/dev/null)

    if [[ -z "$response" ]]; then
        _nh_log "no response, backing off 5s"
        _nh_backoff_until=$(( EPOCHSECONDS + 5 ))
        return
    fi

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

    _nh_query "$BUFFER" "$CURSOR"
}

zle -N zle-line-pre-redraw _nh_pre_redraw

# --- Accept suggestion ---
_nh_accept() {
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
