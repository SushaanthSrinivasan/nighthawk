#!/usr/bin/env zsh
# nighthawk zsh plugin — inline ghost text autocomplete
#
# Install: add to ~/.zshrc:  source /path/to/nighthawk.zsh
# Requires: socat, jq

# --- Configuration ---
NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"

# --- State ---
typeset -g _nh_suggestion=""
typeset -g _nh_replace_start=""
typeset -g _nh_replace_end=""
typeset -g _nh_last_buffer=""
typeset -g _nh_has_highlight=0

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

_nh_clear_ghost() {
    unset POSTDISPLAY
    if (( _nh_has_highlight )); then
        region_highlight[-1]=()
        _nh_has_highlight=0
    fi
    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
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

    # Parse first suggestion
    local text replace_start replace_end
    eval $(echo "$response" | jq -r '
        if (.suggestions | length) > 0 then
            "text=" + (.suggestions[0].text | @sh) +
            " replace_start=" + (.suggestions[0].replace_start | tostring) +
            " replace_end=" + (.suggestions[0].replace_end | tostring)
        else
            "text='"''"'"
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

        # Clear ghost state first
        _nh_clear_ghost

        # Replace the token: BUFFER[0..rstart] + suggestion + BUFFER[rend..]
        # Zsh strings are 1-indexed
        local before="${BUFFER[1,$rstart]}"
        local after="${BUFFER[$((rend + 1)),-1]}"
        BUFFER="${before}${suggestion}${after}"
        CURSOR=${#BUFFER}

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
    # Must clear POSTDISPLAY before accept-line, otherwise the ghost text
    # gets baked into the displayed command line.
    unset POSTDISPLAY
    region_highlight=()
    _nh_has_highlight=0
    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
    _nh_last_buffer="$BUFFER"
    zle accept-line
}

zle -N _nh_line_finish
bindkey '^M' _nh_line_finish
