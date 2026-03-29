#!/usr/bin/env zsh
# nighthawk zsh plugin — inline ghost text autocomplete
#
# Install: add to ~/.zshrc:  source /path/to/nighthawk.zsh
# Requires: socat, jq

# --- Configuration ---
NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"
NIGHTHAWK_FUZZY_DISPLAY="${NIGHTHAWK_FUZZY_DISPLAY:-hint}"

# --- State ---
typeset -g _nh_suggestion=""
typeset -g _nh_replace_start=""
typeset -g _nh_replace_end=""
typeset -g _nh_last_buffer=""
typeset -g _nh_has_highlight=0
typeset -g _nh_diff_ops=""
typeset -g _nh_original_buffer=""
typeset -g _nh_original_cursor=""

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
    # Zsh strings are 1-indexed; replace_start/end are 0-indexed byte offsets
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
        POSTDISPLAY=" → $suggestion"
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

_nh_clear_ghost() {
    unset POSTDISPLAY

    # Remove highlight entries we added
    if (( _nh_has_highlight )); then
        local i
        for i in $(seq $_nh_has_highlight); do
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
    _nh_ensure_daemon

    local buffer="$1"
    local cursor="$2"

    # Escape for JSON: backslashes then double quotes
    local escaped_buffer="${buffer//\\/\\\\}"
    escaped_buffer="${escaped_buffer//\"/\\\"}"
    local escaped_cwd="${PWD//\\/\\\\}"
    escaped_cwd="${escaped_cwd//\"/\\\"}"

    local json="{\"input\":\"${escaped_buffer}\",\"cursor\":${cursor},\"cwd\":\"${escaped_cwd}\",\"shell\":\"zsh\"}"

    local response
    response=$(echo "$json" | socat -t1 - UNIX-CONNECT:"$NIGHTHAWK_SOCKET" 2>/dev/null)

    if [[ -z "$response" ]]; then
        return
    fi

    # Parse first suggestion (text, replace range, and diff_ops if present)
    local text replace_start replace_end diff_ops_str
    eval $(echo "$response" | jq -r '
        if (.suggestions | length) > 0 then
            "text=" + (.suggestions[0].text | @sh) +
            " replace_start=" + (.suggestions[0].replace_start | tostring) +
            " replace_end=" + (.suggestions[0].replace_end | tostring) +
            " diff_ops_str=" + ((.suggestions[0].diff_ops // null) | if . then [.[] | .op[0:1] + ":" + .ch] | join(" ") | @sh else ("" | @sh) end)
        else
            "text='"''"'"
        end
    ' 2>/dev/null)

    if [[ -n "$text" ]]; then
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
            # Prefix match: render ghost text suffix
            local already_typed_len=$(( cursor - replace_start ))
            if (( already_typed_len >= 0 && already_typed_len < ${#text} )); then
                local ghost="${text:$already_typed_len}"
                _nh_render_ghost "$ghost"
            fi
        fi
    fi
}

# --- ZLE hooks ---

# Save existing hook if any
if zle -l zle-line-pre-redraw; then
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
