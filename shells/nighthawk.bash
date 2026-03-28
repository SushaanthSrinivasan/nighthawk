#!/usr/bin/env bash
# nighthawk bash plugin
#
# Architecture:
#   Uses bind -x to hook into readline. On each keystroke,
#   reads $READLINE_LINE → sends JSON to daemon → renders ghost text.
#
# Install:
#   Add to ~/.bashrc: source /path/to/nighthawk.bash
#
# Contract:
#   1. Connect to daemon socket
#   2. On keystroke: send CompletionRequest JSON
#   3. Read CompletionResponse JSON
#   4. Render ghost text via ANSI escapes after cursor
#   5. Tab: accept suggestion into READLINE_LINE

NIGHTHAWK_SOCKET="${NIGHTHAWK_SOCKET:-/tmp/nighthawk-$(id -u).sock}"

# TODO: Implement using bind -x and READLINE_LINE/READLINE_POINT
# bind -x '"\C-_": _nh_suggest'

_nh_suggest() {
    # Placeholder — will query daemon over socket
    :
}

_nh_accept() {
    # Placeholder — will insert suggestion into READLINE_LINE
    :
}
