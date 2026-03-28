#!/usr/bin/env fish
# nighthawk fish plugin
#
# Architecture:
#   Uses fish key bindings to hook into the command line editor.
#   Communicates with daemon over Unix socket.
#
# Install:
#   Add to ~/.config/fish/config.fish: source /path/to/nighthawk.fish
#
# Contract:
#   1. Connect to daemon socket
#   2. On keystroke: send CompletionRequest JSON with commandline buffer
#   3. Read CompletionResponse JSON
#   4. Render ghost text via ANSI escapes
#   5. Tab/Right-arrow: accept suggestion

set -g NIGHTHAWK_SOCKET "/tmp/nighthawk-"(id -u)".sock"

# TODO: Implement using fish key bindings
# bind \t _nh_accept

function _nh_suggest
    # Placeholder — will query daemon over socket
end

function _nh_accept
    # Placeholder — will accept the current suggestion
end
