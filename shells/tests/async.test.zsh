#!/usr/bin/env zsh
# Unit tests for the async IPC response path in shells/nighthawk.zsh.
#
# The async rewrite moved the synchronous query body into two testable seams:
#   _nh_handle_response <json>  — parse + validate + render a daemon reply against the snapshot
#   _nh_reply_is_fresh          — the staleness gate (generation counter only; see note below)
#
# Freshness is generation-only: a `zle -F` fd-handler runs OUTSIDE editor context, so $BUFFER/$CURSOR
# read back empty there — a buffer/cursor compare would reject every reply. The generation counter
# (bumped by every cancel / new query, on the same thread as keystrokes) is the complete signal.
# Both are pure functions of globals we can set directly, so we exercise them WITHOUT a live fd,
# a real daemon, or ZLE — the same hermetic approach as offsets.test.zsh (which AST-isolates the
# byte/char helpers). The live fd plumbing (zle -F, the sleep-timer, socat) is covered by manual
# testing in a real zsh session, per project convention.
#
# Control-char note: JSON forbids raw 0x00-0x1f, and zsh `echo` (in the plugin's `echo|jq`
# pipeline) interprets backslash escapes — so a  on the wire is rejected at the jq-parse
# layer. 0x7f (DEL) is the one control char JSON allows RAW, so it survives jq and is what lets us
# drive _nh_has_ctrl_char end-to-end below.
#
# Requires zsh, socat, jq on PATH (the plugin returns early without socat/jq, so the functions
# wouldn't be defined — caught below as a loud failure).
#
# Run:  zsh shells/tests/async.test.zsh
emulate -L zsh

# --- Hermetic source ---
# Shadow the interactive ZLE builtins so widget/keymap registration is inert during sourcing, and
# isolate config to a temp dir. We also set NIGHTHAWK_DEBOUNCE_MS to a non-numeric value up front
# to exercise the load-time validation (asserted at the end).
#
# The `zle` stub is inert for every flag form (-N/-F/-A/-R/-l registration and repaint), but when
# the plugin invokes a widget BY NAME (`zle _nh_apply_response`) it dispatches to the real function.
# That's deliberate: the live render path is fd-handler -> `zle <widget>` -> render (the fd handler
# can't touch $BUFFER/$POSTDISPLAY itself; only a real widget runs in editor context). Dispatching
# by-name here lets _nh_on_response's tests drive that delegation end-to-end without a live ZLE.
zle() {
    [[ "$1" == -* ]] && return 0
    (( $+functions[$1] )) && "$1"
}
bindkey() { : }
export NIGHTHAWK_DEBOUNCE_MS=foo   # must be clamped to the 200 default, not left to throw later

_nh_tmpcfg=$(mktemp -d)
export XDG_CONFIG_HOME=$_nh_tmpcfg
_nh_plugin="${0:A:h}/../nighthawk.zsh"
if [[ ! -r "$_nh_plugin" ]]; then
    print -u2 "async.test.zsh: cannot read $_nh_plugin"
    rm -rf "$_nh_tmpcfg"
    exit 2
fi
source "$_nh_plugin"
rm -rf "$_nh_tmpcfg"

# Structural check: the async seams must exist (guards against a rename or missing deps).
if (( ! $+functions[_nh_handle_response] || ! $+functions[_nh_reply_is_fresh] || ! $+functions[_nh_has_ctrl_char] )); then
    print -u2 "async.test.zsh: FAIL — async functions not defined after sourcing (renamed? deps missing?)"
    exit 2
fi

# --- Assertion harness ---
typeset -gi _nh_pass=0 _nh_fail=0
check() {  # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( _nh_pass++ ))
    else
        (( _nh_fail++ ))
        print -r -- "FAIL: $1 — expected '$2' got '$3'"
    fi
}

# Reset everything _nh_handle_response reads or writes, then point the snapshot at <buffer>/<cursor>.
# BUFFER is set to match the snapshot because the render helpers index region_highlight off ${#BUFFER}.
reset_state() {  # reset_state <buffer> <cursor>
    _nh_suggestion=""
    _nh_replace_start=""
    _nh_replace_end=""
    _nh_diff_ops=""
    _nh_original_buffer=""
    _nh_has_highlight=0
    region_highlight=()
    unset POSTDISPLAY
    _nh_inflight_buffer="$1"
    _nh_inflight_cursor="$2"
    BUFFER="$1"
    CURSOR="$2"
}

DEL=$'\x7f'   # 0x7f: a control char JSON permits raw, so it reaches _nh_has_ctrl_char through jq.

# ---------------------------------------------------------------------------
# 1. True prefix match -> suffix rendered as ghost (POSTDISPLAY), full text published.
#    buffer "git ch" (6 bytes), replace [0,6), text "git checkout" -> ghost "eckout".
# ---------------------------------------------------------------------------
reset_state "git ch" 6
_nh_handle_response '{"suggestions":[{"text":"git checkout","replace_start":0,"replace_end":6}]}'
check "prefix: suggestion published" "git checkout" "$_nh_suggestion"
check "prefix: ghost is the suffix"  "eckout"       "$POSTDISPLAY"

# ---------------------------------------------------------------------------
# 2. Replacement that changes the typed text -> hint (" -> text"), not an inline ghost.
#    buffer "gti", replace [0,3), text "git status": longer than what's typed AND its first 3
#    chars ("git") differ from the typed "gti", so it renders as a hint.
# ---------------------------------------------------------------------------
reset_state "gti" 3
_nh_handle_response '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}'
check "replacement: suggestion published" "git status"               "$_nh_suggestion"
check "replacement: rendered as hint"     " $_nh_hint_arrow git status" "$POSTDISPLAY"

# ---------------------------------------------------------------------------
# 3. Fuzzy match with diff_ops, default hint display mode -> hint POSTDISPLAY.
# ---------------------------------------------------------------------------
reset_state "gti" 3
_nh_handle_response '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3,"diff_ops":[{"op":"keep","ch":"g"},{"op":"insert","ch":"i"}]}]}'
check "fuzzy hint: suggestion published" "git status"               "$_nh_suggestion"
check "fuzzy hint: hint rendered"        " $_nh_hint_arrow git status" "$POSTDISPLAY"

# ---------------------------------------------------------------------------
# 4. Control char in suggestion text -> fail closed, nothing published (RCE/escape guard).
#    Raw 0x7f reaches $text through jq and must be rejected by _nh_has_ctrl_char before publish.
# ---------------------------------------------------------------------------
reset_state "ls" 2
_nh_handle_response '{"suggestions":[{"text":"ls'"${DEL}"'x","replace_start":0,"replace_end":2}]}'
check "ctrl in text: nothing published" "" "$_nh_suggestion"
check "ctrl in text: no ghost"          "" "${POSTDISPLAY-}"

# ---------------------------------------------------------------------------
# 5. Clean text but a control char inside diff_ops -> still rejected (the per-op bytes reach BUFFER
#    in diff mode, so a clean text with a tainted op must not slip the text-only check above).
# ---------------------------------------------------------------------------
reset_state "gti" 3
_nh_handle_response '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3,"diff_ops":[{"op":"insert","ch":"'"${DEL}"'"}]}]}'
check "ctrl in diff_ops: nothing published" "" "$_nh_suggestion"
check "ctrl in diff_ops: no ghost"          "" "${POSTDISPLAY-}"

# ---------------------------------------------------------------------------
# 6. Out-of-range replace_end (past end of buffer) -> fail closed, never corrupt the buffer.
# ---------------------------------------------------------------------------
reset_state "ls" 2
_nh_handle_response '{"suggestions":[{"text":"ls -la","replace_start":0,"replace_end":99}]}'
check "oob range: nothing published" "" "$_nh_suggestion"
check "oob range: no ghost"          "" "${POSTDISPLAY-}"

# ---------------------------------------------------------------------------
# 7. Empty suggestion list -> no-op.
# ---------------------------------------------------------------------------
reset_state "git" 3
_nh_handle_response '{"suggestions":[]}'
check "empty list: nothing published" "" "$_nh_suggestion"

# ---------------------------------------------------------------------------
# 8. _nh_has_ctrl_char primitive: the security gate itself, across the full rejected range.
# ---------------------------------------------------------------------------
ctrl_of() { _nh_has_ctrl_char "$1" && print detected || print clean }
check "ctrl primitive: 0x01"       detected "$(ctrl_of $'\x01')"
check "ctrl primitive: 0x1f"       detected "$(ctrl_of $'\x1f')"
check "ctrl primitive: 0x7f (DEL)" detected "$(ctrl_of $'\x7f')"
check "ctrl primitive: newline"    detected "$(ctrl_of $'a\nb')"
check "ctrl primitive: clean text" clean    "$(ctrl_of 'git checkout --force')"

# ---------------------------------------------------------------------------
# 9. Staleness gate: _nh_reply_is_fresh is true iff the generation still matches dispatch. Buffer and
#    cursor are deliberately NOT consulted — they're unreadable in the fd-handler context where this
#    runs (see header note), and every buffer/cursor change already bumps the generation anyway.
# ---------------------------------------------------------------------------
fresh_of() {  # fresh_of <gen> <dispatch_gen> <buffer> <inflight_buffer> <cursor> <inflight_cursor>
    _nh_gen=$1 _nh_dispatch_gen=$2 BUFFER="$3" _nh_inflight_buffer="$4" CURSOR=$5 _nh_inflight_cursor=$6
    _nh_reply_is_fresh && print fresh || print stale
}
check "fresh: all match"          fresh "$(fresh_of 5 5 git git 3 3)"
check "stale: generation moved"   stale "$(fresh_of 6 5 git git 3 3)"
# Buffer/cursor differences do NOT mark stale on their own — only the generation gates freshness.
check "fresh: buffer diff ignored" fresh "$(fresh_of 5 5 gitx git 4 3)"
check "fresh: cursor diff ignored" fresh "$(fresh_of 5 5 git git 2 3)"

# ---------------------------------------------------------------------------
# 10. Load-time debounce validation: the non-numeric NIGHTHAWK_DEBOUNCE_MS=foo set before sourcing
#     must have been clamped to the 200 default (otherwise / 1000.0 throws in the keystroke path).
# ---------------------------------------------------------------------------
check "debounce_ms clamped from non-numeric" 200 "$_nh_debounce_ms"

# ---------------------------------------------------------------------------
# 11. _nh_on_response drain loop — the seam the assertions above skip. Driven with REAL fds so it
#     catches the two failure modes a plan-only review can't: a crash on every reply, and
#     mid-stream truncation of a multi-chunk reply. (A regular file gives "data then EOF"
#     deterministically; a <>-opened fifo gives "data, no EOF" to model a still-arriving reply.)
# ---------------------------------------------------------------------------
# 11a. A complete line delivered in one read -> drains, passes the freshness gate, renders the ghost
#      and tears the fd down. (If `local status=$?` regressed, the handler would abort here and
#      POSTDISPLAY would stay empty — this is the crash regression guard.)
reset_state "git ch" 6
_nh_gen=20 _nh_dispatch_gen=20
_nh_resp_accum=""
_nh_t=$(mktemp)
print -r -- '{"suggestions":[{"text":"git checkout","replace_start":0,"replace_end":6}]}' > "$_nh_t"
exec {_nh_fd}< "$_nh_t"; _nh_resp_fd=$_nh_fd
_nh_on_response $_nh_fd ""
check "on_response: full line renders ghost"     "eckout" "${POSTDISPLAY-}"
check "on_response: fd torn down after finalize" 0        "$_nh_resp_fd"
rm -f "$_nh_t"

# 11b. Reply split across callbacks: a partial already sits in the accumulator and the fd carries
#      the remainder -> the two must be joined (append, not overwrite) and parsed as one line.
reset_state "git ch" 6
_nh_gen=21 _nh_dispatch_gen=21
_nh_resp_accum='{"suggestions":[{"text":"git che'
_nh_t=$(mktemp)
print -r -- 'ckout","replace_start":0,"replace_end":6}]}' > "$_nh_t"
exec {_nh_fd}< "$_nh_t"; _nh_resp_fd=$_nh_fd
_nh_on_response $_nh_fd ""
check "on_response: accumulates across chunks" "eckout" "${POSTDISPLAY-}"
rm -f "$_nh_t"

# 11c. A partial with no newline and NO EOF (write end held open via <>) must NOT finalize — it
#      stays registered for the next callback instead of truncating. Regression guard for the
#      "while-loop masks the sysread status" bug: if would-block (4) were misread as done, this
#      would tear the fd down and feed jq a truncated line.
reset_state "ls" 2
_nh_gen=22 _nh_dispatch_gen=22
_nh_resp_accum=""
_nh_fifo=$(mktemp -u); mkfifo "$_nh_fifo"
exec {_nh_fd}<> "$_nh_fifo"          # read-write: readable, but never EOF while we hold it
print -rn -- '{"suggestions":[{"text":"ls' >&$_nh_fd
_nh_resp_fd=$_nh_fd
_nh_on_response $_nh_fd ""
check "on_response: partial w/o newline does not finalize" "" "${POSTDISPLAY-}"
check "on_response: partial keeps fd registered" "$_nh_fd" "$_nh_resp_fd"
exec {_nh_fd}<&-; rm -f "$_nh_fifo"

# 11d. A complete line, but the generation moved on since dispatch (superseded by a later keystroke)
#      -> drained and dropped by the freshness gate, nothing rendered.
reset_state "git ch" 6
_nh_gen=24 _nh_dispatch_gen=23       # dispatch one generation behind => stale
_nh_resp_accum=""
_nh_t=$(mktemp)
print -r -- '{"suggestions":[{"text":"git checkout","replace_start":0,"replace_end":6}]}' > "$_nh_t"
exec {_nh_fd}< "$_nh_t"; _nh_resp_fd=$_nh_fd
_nh_on_response $_nh_fd ""
check "on_response: stale generation renders nothing" "" "${POSTDISPLAY-}"
rm -f "$_nh_t"

# --- summary ---
print -r -- "async.test.zsh: $_nh_pass passed, $_nh_fail failed"
(( _nh_fail == 0 ))
