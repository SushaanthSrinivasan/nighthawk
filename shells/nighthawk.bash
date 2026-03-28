#!/usr/bin/env bash
# nighthawk bash plugin — inline ghost text autocomplete
#
# Install: add to ~/.bashrc:  source /path/to/nighthawk.bash
# Requires: socat, jq

# --- Configuration ---
NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"

# --- State ---
_nh_suggestion=""
_nh_replace_start=""
_nh_replace_end=""
_nh_last_buffer=""

# --- Dependency check ---
if ! command -v socat &>/dev/null; then
    echo "nighthawk: socat not found, install with: apt install socat" >&2
    return 1
fi
if ! command -v jq &>/dev/null; then
    echo "nighthawk: jq not found, install with: apt install jq" >&2
    return 1
fi

# --- Ghost text rendering ---
_nh_render_ghost() {
    local ghost="$1"
    if [[ -n "$ghost" ]]; then
        # Save cursor, move to end of line, print gray text, restore cursor
        # \033[s: save cursor, \033[K: clear to end of line, \033[90m: gray, \033[0m: reset, \033[u: restore
        printf "\033[s%b%s%b\033[u" "\033[90m" "$ghost" "\033[0m" >&2
    fi
}

_nh_clear_ghost() {
    # Move to end of current buffer and clear to end of line
    local buffer_len=${#READLINE_LINE}
    local cursor_pos=$READLINE_POINT
    local offset=$((buffer_len - cursor_pos))
    
    # Save, move forward to end of buffer, clear, restore
    if (( offset > 0 )); then
        printf "\033[s\033[%dC\033[K\033[u" "$offset" >&2
    else
        printf "\033[s\033[K\033[u" >&2
    fi
    
    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
}

# --- Daemon communication ---
_nh_query() {
    local buffer="$1"
    local cursor="$2"

    # Escape for JSON: backslashes then double quotes
    local escaped_buffer="${buffer//\\/\\\\}"
    escaped_buffer="${escaped_buffer//\"/\\\"}"
    local escaped_cwd="${PWD//\\/\\\\}"
    escaped_cwd="${escaped_cwd//\"/\\\"}"

    local json="{\"input\":\"${escaped_buffer}\",\"cursor\":${cursor},\"cwd\":\"${escaped_cwd}\",\"shell\":\"bash\"}"

    local response
    response=$(echo "$json" | socat -t1 - UNIX-CONNECT:"$NIGHTHAWK_SOCKET" 2>/dev/null)

    if [[ -z "$response" ]]; then
        return
    fi

    # Parse first suggestion
    local text replace_start replace_end
    eval $(echo "$response" | jq -r '
        if (.suggestions | length) > 0 then
            "text=" + (.suggestions[0].text | @sh) +
            " replace_start=" + (.suggestions[0].replace_start | tostring) +
            " replace_end=" + (.suggestions[0].replace_end | tostring)
        else
            "text=" + ("" | @sh)
        end
    ' 2>/dev/null)

    if [[ -n "$text" ]]; then
        _nh_suggestion="$text"
        _nh_replace_start="$replace_start"
        _nh_replace_end="$replace_end"

        # Compute ghost text: the suffix beyond what user already typed
        local already_typed_len=$(( cursor - replace_start ))
        if (( already_typed_len >= 0 && already_typed_len < ${#text} )); then
            local ghost="${text:$already_typed_len}"
            _nh_render_ghost "$ghost"
        fi
    fi
}

# --- Key handlers ---

_nh_suggest() {
    _nh_clear_ghost
    
    # Only suggest when cursor is at end of line
    (( READLINE_POINT != ${#READLINE_LINE} )) && return
    
    # Need at least 2 chars
    (( ${#READLINE_LINE} < 2 )) && return
    
    _nh_query "$READLINE_LINE" "$READLINE_POINT"
}

_nh_keypress() {
    local char="$1"
    # Insert char at current point
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${char}${READLINE_LINE:READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT + 1))
    _nh_suggest
}

_nh_backspace() {
    if (( READLINE_POINT > 0 )); then
        READLINE_LINE="${READLINE_LINE:0:READLINE_POINT-1}${READLINE_LINE:READLINE_POINT}"
        READLINE_POINT=$((READLINE_POINT - 1))
    fi
    _nh_suggest
}

_nh_accept() {
    if [[ -n "$_nh_suggestion" && "$_nh_replace_start" != "" && "$_nh_replace_end" != "" ]]; then
        local suggestion="$_nh_suggestion"
        local rstart="$_nh_replace_start"
        local rend="$_nh_replace_end"

        # Clear ghost state first
        _nh_clear_ghost

        # Replace the token
        local before="${READLINE_LINE:0:rstart}"
        local after="${READLINE_LINE:rend}"
        READLINE_LINE="${before}${suggestion}${after}"
        READLINE_POINT=${#READLINE_LINE}
    else
        # Fall through to default Tab
        # Send raw tab key sequence to readline
        printf "\t" > /dev/tty
    fi
}

# --- Initialization ---

# Bind Tab to accept suggestion
bind -x '"\C-i": _nh_accept'

# Bind printable characters to hook into keystrokes
# Note: this is heavy in Bash. We only bind a subset of common chars.
for c in {a..z} {A..Z} {0..9} ' ' '-' '_' '.' '/' '@' '=' ':' '+' ','; do
    bind -x "\"$c\": _nh_keypress '$c'"
done

# Bind Backspace
bind -x '"\C-h": _nh_backspace'
bind -x '"\C-?": _nh_backspace'

# Bind Enter to clear ghost
bind -x '"\C-m": _nh_clear_ghost; printf "\n" > /dev/tty'
