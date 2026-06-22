#!/usr/bin/env bash
# Unit tests for the pure helpers in shells/nighthawk.bash.
#
# This is the bash analogue of shells/tests/offsets.test.zsh, extended to cover the
# config/clamp, control-char, JSON-escape, parse, and prefix-vs-hint logic that the bash
# port factors into pure functions. It is hermetic: config is isolated to a temp
# XDG_CONFIG_HOME, NIGHTHAWK_* env overrides are unset, and the interactive `bind` builtin
# is stubbed to a no-op so sourcing has no side effects. (Session 1 makes no bind calls,
# but the stub future-proofs the harness for Session 2.)
#
# Requires the same tools the plugin does (bash, socat, jq on PATH) AND a UTF-8 locale — run on
# Linux/WSL, not a bare Windows shell. The 10 pure helpers are all defined ABOVE the plugin's
# dep-check, so the structural check below passes even on a depless box; what actually fails
# there are the jq-backed parse/pipeline assertions (and the offset rows need UTF-8). The
# structural check guards against a rename of those helpers, not against missing deps.
#
# Run:  bash shells/tests/helpers.test.bash

# --- Hermetic source ---
bind() { :; }                                  # shadow the readline builtin (inert)
_nh_tmpcfg=$(mktemp -d)
export XDG_CONFIG_HOME="$_nh_tmpcfg"
unset NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_SOCKET

_nh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_nh_plugin="$_nh_dir/../nighthawk.bash"
if [[ ! -r "$_nh_plugin" ]]; then
    echo "helpers.test.bash: cannot read $_nh_plugin" >&2
    rm -rf "$_nh_tmpcfg"
    exit 2
fi
# `source` (not execute) so the plugin's `return 1` dep-check can't exit this process.
source "$_nh_plugin"

# Structural check: the helpers must exist after sourcing (guards a rename / missing deps).
# Includes the Session-3 cross-process helpers (_nh_ms_to_sec pure; _nh_bump_gen/_nh_accept etc.
# defined OUTSIDE the interactive guard so they're unit-testable with an injected _nh_run_dir).
for fn in _nh_load_config _nh_log _nh_has_ctrl_char _nh_byte_to_char _nh_char_to_byte \
          _nh_json_escape _nh_build_request _nh_parse_response _nh_decide_render \
          _nh_compute_suggestion _nh_ms_to_sec _nh_bump_gen _nh_accept _nh_forward_or_accept \
          _nh_tab_widget _nh_dismiss _nh_stash_ready; do
    if ! declare -F "$fn" >/dev/null; then
        echo "helpers.test.bash: FAIL — $fn not defined after sourcing plugin (renamed? deps missing?)" >&2
        rm -rf "$_nh_tmpcfg"
        exit 2
    fi
done

# The Session-3 live layer writes the ghost to /dev/tty via _nh_tty_write. Stub it to a no-op so
# the accept/clear/motion tests don't spray ANSI at (or fail on the absence of) a real terminal —
# the analogue of the `bind` shadow above. The cross-process gen/stash FILES are exercised for
# real against a scaffolded temp _nh_run_dir; only the tty paint is stubbed.
_nh_tty_write() { :; }

# --- Assertion harness ---
_nh_pass=0
_nh_fail=0
check() {  # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        (( _nh_pass++ ))
    else
        (( _nh_fail++ ))
        printf "FAIL: %s — expected '%s' got '%s'\n" "$1" "$2" "$3"
    fi
}

# ======================================================================================
# Offset converters — mirrors offsets.test.zsh. Test data built from RAW UTF-8 BYTES (not
# $'\U...', which is non-portable in bash) so it survives any file-encoding round-trip.
#   a = U+0061 (1B)  é = U+00E9 (2B)  中 = U+4E2D (3B)  😀 = U+1F600 (4B)  é = U+00E9 (2B)
#   => byte boundaries 0,1,3,6,10,12 ; 5 char units.
# ======================================================================================
S=$'\x61\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80\xc3\xa9'

# --- ASCII (byte == char identity) ---
A="git checkout"
check "ascii b2c 0"        0  "$(_nh_byte_to_char "$A" 0)"
check "ascii b2c 4"        4  "$(_nh_byte_to_char "$A" 4)"
check "ascii b2c 12 (EOL)" 12 "$(_nh_byte_to_char "$A" 12)"
check "ascii c2b 4"        4  "$(_nh_char_to_byte "$A" 4)"
check "ascii c2b 12 (EOL)" 12 "$(_nh_char_to_byte "$A" 12)"

# --- byte_to_char on code-point boundaries (2/3-byte sequences) ---
check "b2c 0"            0 "$(_nh_byte_to_char "$S" 0)"
check "b2c 1 (after 1B)" 1 "$(_nh_byte_to_char "$S" 1)"
check "b2c 3 (after 2B)" 2 "$(_nh_byte_to_char "$S" 3)"
check "b2c 6 (after 3B)" 3 "$(_nh_byte_to_char "$S" 6)"
check "b2c 12 (EOL)"     5 "$(_nh_byte_to_char "$S" 12)"

# --- mid-sequence rejections (fail-closed -> -1) ---
check "b2c 2 (mid 2-byte)" -1 "$(_nh_byte_to_char "$S" 2)"
check "b2c 4 (mid 3-byte)" -1 "$(_nh_byte_to_char "$S" 4)"
check "b2c 5 (mid 3-byte)" -1 "$(_nh_byte_to_char "$S" 5)"

# --- bounds & degenerate inputs ---
check "b2c -1 (negative)" -1 "$(_nh_byte_to_char "$S" -1)"
check "b2c 13 (past end)" -1 "$(_nh_byte_to_char "$S" 13)"
check "b2c empty, off 0"   0 "$(_nh_byte_to_char "" 0)"
check "b2c empty, off 1"  -1 "$(_nh_byte_to_char "" 1)"

# --- char_to_byte inverse on boundaries ---
check "c2b 0"  0  "$(_nh_char_to_byte "$S" 0)"
check "c2b 1"  1  "$(_nh_char_to_byte "$S" 1)"
check "c2b 2"  3  "$(_nh_char_to_byte "$S" 2)"
check "c2b 3"  6  "$(_nh_char_to_byte "$S" 3)"
check "c2b 5"  12 "$(_nh_char_to_byte "$S" 5)"
check "c2b past-end clamps" 12 "$(_nh_char_to_byte "$S" 99)"
check "c2b negative -> 0"    0 "$(_nh_char_to_byte "$S" -3)"

# --- _nh_eol_bytes: byte length of the whole string (= byte offset of EOL). Robust even on a
# libc that miscounts astral chars, since it measures the full string regardless of char count. ---
check "eol_bytes ascii"     12 "$(_nh_eol_bytes "$A")"
check "eol_bytes multibyte" 12 "$(_nh_eol_bytes "$S")"
check "eol_bytes empty"      0 "$(_nh_eol_bytes "")"

# --- round-trip over every boundary ---
for i in 0 1 2 3 5; do
    b=$(_nh_char_to_byte "$S" $i)
    check "roundtrip char $i (byte $b)" $i "$(_nh_byte_to_char "$S" $b)"
done

# --- 4-byte (astral) coverage — probe-gated. The substring-length walk needs the libc to
# decode a 4-byte char as one unit under the UTF-8 locale; some glibc builds miscount it as
# 2. Where that happens the converters still fail CLOSED at runtime (wrong offset -> daemon
# reply fails validation -> no ghost), so we skip the rows rather than fail the suite. ---
_nh_astral=$'\xf0\x9f\x98\x80'
if [[ ${#_nh_astral} == 1 ]]; then
    check "b2c 10 (after 4B)"  4 "$(_nh_byte_to_char "$S" 10)"
    check "b2c 7 (mid 4-byte)" -1 "$(_nh_byte_to_char "$S" 7)"
    check "b2c 8 (mid 4-byte)" -1 "$(_nh_byte_to_char "$S" 8)"
    check "b2c 9 (mid 4-byte)" -1 "$(_nh_byte_to_char "$S" 9)"
    check "c2b 4" 10 "$(_nh_char_to_byte "$S" 4)"
    b=$(_nh_char_to_byte "$S" 4)
    check "roundtrip char 4 (byte $b)" 4 "$(_nh_byte_to_char "$S" $b)"
else
    echo "NOTE: astral char miscounts as ${#_nh_astral} on this libc — 4-byte rows skipped (runtime fails closed)"
fi

# ======================================================================================
# Control-char guard (fail-closed rejection)
# ======================================================================================
_nh_has_ctrl_char "git status" ; check "ctrl: clean cmd accepted"  1 "$?"
_nh_has_ctrl_char $'ls\nrm'    ; check "ctrl: newline rejected"    0 "$?"
_nh_has_ctrl_char $'a\x1bb'    ; check "ctrl: ESC rejected"        0 "$?"
_nh_has_ctrl_char $'a\x7f'     ; check "ctrl: DEL rejected"        0 "$?"
_nh_has_ctrl_char $'a\tb'      ; check "ctrl: TAB rejected"        0 "$?"
_nh_has_ctrl_char "echo 中"    ; check "ctrl: multibyte accepted"  1 "$?"

# ======================================================================================
# JSON escaping + request build
# ======================================================================================
check "esc backslash" 'a\\b'      "$(_nh_json_escape 'a\b')"
check "esc quote"      'say \"hi\"' "$(_nh_json_escape 'say "hi"')"
check "esc tab"        'x\ty'      "$(_nh_json_escape $'x\ty')"
check "esc newline"    'x\ny'      "$(_nh_json_escape $'x\ny')"
check "esc C0 0x01"    'a\u0001b'  "$(_nh_json_escape $'a\x01b')"
# 0x1b (ESC) is unnamed, so it is exercised ONLY by the C0 escape loop, not the named escapes
# above — guards against a future edit dropping ESC (the most render-dangerous byte). The
# expected is built via printf because the source can't portably carry a lone backslash-u:
# printf consumes the DOUBLED backslash atomically (yields one backslash) and does NOT
# reinterpret the trailing u001b, so _esc_expect holds the literal that json_escape emits.
printf -v _esc_expect 'a\\u001bb'
check "esc C0 0x1b ESC" "$_esc_expect" "$(_nh_json_escape $'a\x1bb')"
check "esc plain passthrough" 'git 中' "$(_nh_json_escape 'git 中')"
check "build request" '{"input":"git st","cursor":6,"cwd":"/home/u","shell":"bash"}' \
    "$(_nh_build_request 'git st' 6 '/home/u')"
check "build request escapes quote" '{"input":"echo \"hi\"","cursor":9,"cwd":"/w","shell":"bash"}' \
    "$(_nh_build_request 'echo "hi"' 9 '/w')"

# ======================================================================================
# Response parse (eval-able assignments; _nh_parse_response self-defaults all four fields)
# ======================================================================================
parse_into() {  # parse_into <json>  -> sets text/replace_start/replace_end/diff_ops_present
    # No manual defaulting here: _nh_parse_response is self-defaulting, so a bare eval can't
    # leave stale values from a prior parse. (Exercises that contract directly — see the
    # "not stale" case below, which seeds a sentinel first.)
    eval "$(_nh_parse_response "$1")"
}
parse_into '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}'
check "parse text"          "git status" "$text"
check "parse rstart"        "0"          "$replace_start"
check "parse rend"          "3"          "$replace_end"
check "parse no diff"       "0"          "$diff_ops_present"
parse_into '{"suggestions":[{"text":"grep","replace_start":0,"replace_end":2,"diff_ops":[{"op":"keep","ch":"g"}]}]}'
check "parse diff present"  "1"          "$diff_ops_present"
parse_into '{"suggestions":[]}'
check "parse empty -> no text" "" "$text"
# Seed a sentinel, then parse garbage: jq fails (no output), so ONLY the self-defaulting in
# _nh_parse_response can clear it. Proves the reset survives a parse_into with no manual reset.
text="STALE" replace_start="9" replace_end="9" diff_ops_present=1
parse_into 'not json at all'
check "parse malformed -> no text (not stale)" "" "$text"
check "parse malformed -> rstart cleared"      "" "$replace_start"
check "parse malformed -> diff flag cleared"   "0" "$diff_ops_present"

# ======================================================================================
# Decision logic + full pipeline (prefix-vs-hint)
# ======================================================================================
# True prefix: buffer "git", suggestion "git status" replacing [0,3) -> ghost suffix.
check "decide ghost (prefix)" $'ghost\t status' \
    "$(_nh_decide_render 'git' 'git status' 0 0)"
# Divergent typed text -> hint with arrow.
check "decide hint (divergent)" $'hint\t -> git status' \
    "$(_nh_decide_render 'gti' 'git status' 0 0)"
# diff present -> always hint.
check "decide hint (diff)" $'hint\t -> git status' \
    "$(_nh_decide_render 'git' 'git status' 0 1)"
# Self-guard: negative rstart (failed conversion) -> empty, never a bad subscript.
check "decide guards rstart=-1" "" "$(_nh_decide_render 'git' 'git status' -1 0)"
# Empty text -> empty.
check "decide empty text" "" "$(_nh_decide_render 'git' '' 0 0)"
# Boundary: buffer already equals the full suggestion (typed_len == ${#text}) -> nothing to ghost.
# Guards the `typed_len < ${#text}` comparison from a future `<` -> `<=` regression (empty ghost).
check "decide empty when fully typed" "" "$(_nh_decide_render 'git status' 'git status' 0 0)"
# Boundary: rstart past the buffer end (a stale/garbage offset) -> guarded to empty, never a bad
# ${buffer:rstart:...} subscript.
check "decide empty when rstart>blen" "" "$(_nh_decide_render 'git' 'git status' 99 0)"

# End-to-end pipeline through parse + reject + convert + validate + decide. Output is now the
# 5-field record <kind>\t<display>\t<bstart>\t<bend>\t<text>: the display tag plus the daemon's
# BYTE range + replacement text for the accept path. (bstart/bend equal the char offsets here
# because the buffers are ASCII.)
check "pipeline ghost" $'ghost\t status\t0\t3\tgit status' \
    "$(_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')"
check "pipeline hint (divergent)" $'hint\t -> git status\t0\t3\tgit status' \
    "$(_nh_compute_suggestion 'gti' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')"
# Control char in suggestion -> rejected (no output).
check "pipeline rejects ctrl-char suggestion" "" \
    "$(_nh_compute_suggestion 'rm ' '{"suggestions":[{"text":"rm -rf /\n","replace_start":0,"replace_end":3}]}')"
# Malformed range (null) -> no output.
check "pipeline rejects null range" "" \
    "$(_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status"}]}')"
# Zero-padded offset ("09") from a misbehaving daemon: base-10 normalization must parse it as
# 9 (not trip octal in the converters). Before the 10# guard this errored to stderr and the
# suggestion was dropped (empty); now it resolves to the correct ghost suffix.
check "pipeline base-10 normalizes 09" $'ghost\ting\t0\t9\techo testing' \
    "$(_nh_compute_suggestion 'echo test' '{"suggestions":[{"text":"echo testing","replace_start":"00","replace_end":"09"}]}' 2>/dev/null)"
# Multibyte: proves the record carries the daemon's BYTE offsets while the internal prefix
# decision used CHAR offsets. buffer "café" is 5 bytes / 4 chars; replace [0,5) (bytes) with
# "café list" -> ghost suffix " list", and the record's bstart/bend are 0/5 (BYTES, not 0/4).
# The é is built via $'...' into VARIABLES first — a literal \xc3\xa9 inside a "..." JSON
# string is NOT interpreted by bash, so jq would reject the bogus \x escape (empty output).
_mb_buf=$'caf\xc3\xa9'
_mb_txt=$'caf\xc3\xa9 list'
check "pipeline multibyte carries byte offsets" $'ghost\t list\t0\t5\tcaf\xc3\xa9 list' \
    "$(_nh_compute_suggestion "$_mb_buf" "{\"suggestions\":[{\"text\":\"$_mb_txt\",\"replace_start\":0,\"replace_end\":5}]}")"

# ======================================================================================
# 5-field tag parse (the split _nh_suggest performs). IFS must be EXACTLY a tab so the
# display field's load-bearing LEADING SPACE survives — the whole reason hint/ghost payloads
# carry it. A default-IFS read would strip it and mis-render. This asserts the contract the
# render+accept dispatch depends on.
# ======================================================================================
tagparse() {  # tagparse <record> -> sets k/d/bs/be/t from the 5 tab fields
    IFS=$'\t' read -r k d bs be t <<< "$1"
}
tagparse $'ghost\t status\t0\t3\tgit status'
check "tagparse kind"                        "ghost"      "$k"
check "tagparse display keeps leading space" " status"    "$d"
check "tagparse bstart"                      "0"          "$bs"
check "tagparse bend"                        "3"          "$be"
check "tagparse text"                        "git status" "$t"
tagparse $'hint\t -> git status\t0\t3\tgit status'
check "tagparse hint display verbatim"       " -> git status" "$d"

# ======================================================================================
# Session-3 cross-process state: debounce derivation, gen file, stash serde, then the file-driven
# accept gate. Scaffold a temp run dir (the interactive guard never ran, so _nh_run_dir is unset
# and these helpers would otherwise no-op — that no-op IS the non-tty inertness guarantee). The
# path is saved separately because the config-reload section below re-sources the plugin, which
# resets _nh_run_dir="" — so final cleanup must use the saved copy.
# ======================================================================================
_nh_run_dir=$(mktemp -d); _nh_test_rundir="$_nh_run_dir"
_nh_stash() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" > "$_nh_run_dir/stash"; }

# _nh_ms_to_sec: integer-ms -> fractional-seconds string splice. The 50->0.050 row is the
# anti-10x-bug guard (a naive splice would yield 0.50 = 500ms); 0 floors to the 10ms minimum.
check "ms_to_sec 200"         "0.200"  "$(_nh_ms_to_sec 200)"
check "ms_to_sec 50 (no 10x)" "0.050"  "$(_nh_ms_to_sec 50)"
check "ms_to_sec 1500"        "1.500"  "$(_nh_ms_to_sec 1500)"
check "ms_to_sec 10000"       "10.000" "$(_nh_ms_to_sec 10000)"
check "ms_to_sec 10"          "0.010"  "$(_nh_ms_to_sec 10)"
check "ms_to_sec 0 -> floor"  "0.010"  "$(_nh_ms_to_sec 0)"

# _nh_bump_gen: in-process counter and gen FILE move together (single mutator, monotonic).
_nh_gen=0
_nh_bump_gen; check "bump gen var 1" 1 "$_nh_gen"; check "bump gen file 1" 1 "$(cat "$_nh_run_dir/gen")"
_nh_bump_gen; check "bump gen var 2" 2 "$_nh_gen"; check "bump gen file 2" 2 "$(cat "$_nh_run_dir/gen")"

# Stash serde round-trip: the 4 tab fields survive, including a `text` with internal spaces.
_nh_stash 3 0 5 "git commit -m"
IFS=$'\t' read -r _sg _sb _se _st < "$_nh_run_dir/stash"
check "stash gen field"         3               "$_sg"
check "stash bstart field"      0               "$_sb"
check "stash bend field"        5               "$_se"
check "stash text keeps spaces" "git commit -m" "$_st"

# ======================================================================================
# Accept-splice (byte-domain, FILE-DRIVEN). _nh_accept reads the `stash` file, revalidates
# sgen == _nh_gen + EOL + range + control-char against live READLINE_LINE/POINT, then splices the
# [bstart,bend) BYTE range and parks the cursor (byte offset) at the end of the inserted text.
# (Replaces the S2 globals-driven tests — the in-process _nh_sug_* stash is retired cross-process.)
# ======================================================================================
_nh_gen=5
# Happy path: "git" + replace [0,3) with "git status" -> full token, cursor at byte 10.
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 5 0 3 "git status"
_nh_accept
check "accept splices full token"   "git status" "$READLINE_LINE"
check "accept cursor at end (bytes)" "10"         "$READLINE_POINT"
# Stale generation (sgen != live gen) -> rejected, buffer untouched.
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 4 0 3 "git status"
_nh_accept
check "accept rejects stale gen" "git" "$READLINE_LINE"
# Off-EOL (cursor not at buffer end) -> rejected even with a fresh stash (a stash can outlive a move).
# Also asserts the off-EOL reject DROPS the stash (the clear), so a stale ghost can't be re-accepted.
READLINE_LINE="git log"; READLINE_POINT=3
_nh_stash 5 0 3 "git log"
_nh_accept
check "accept rejects off-EOL" "git log" "$READLINE_LINE"
check "accept off-EOL dropped the stash" "" "$([[ -f "$_nh_run_dir/stash" ]] && echo present)"
# Inverted range (bstart > bend, e.g. from a tampered stash) -> fail closed, buffer untouched.
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 5 3 0 "X"
_nh_accept
check "accept bails on inverted range (bstart>bend)" "git" "$READLINE_LINE"
# Out-of-range range (stale bend past end) -> fail closed, buffer untouched.
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 5 0 99 "X"
_nh_accept
check "accept bails on out-of-range range" "git" "$READLINE_LINE"
# No stash file (no live suggestion) -> no-op.
rm -f "$_nh_run_dir/stash"
READLINE_LINE="git"; READLINE_POINT=3
_nh_accept
check "accept bails on missing stash" "git" "$READLINE_LINE"
# Multibyte splice: "café" (5 bytes) replace [0,5) with "café list" -> cursor parks at byte 10.
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=5
_nh_stash 5 0 5 $'caf\xc3\xa9 list'
_nh_accept
check "accept multibyte splice"         $'caf\xc3\xa9 list' "$READLINE_LINE"
check "accept multibyte cursor (bytes)"  10                 "$READLINE_POINT"
# Control-char defense (the security backstop), two complementary properties:
# (1) A planted NON-newline C0 char (ESC) survives `read` and is rejected by _nh_has_ctrl_char.
READLINE_LINE="rm "; READLINE_POINT=3
_nh_stash 5 0 3 $'rm\x1b-rf'
_nh_accept
check "accept rejects ESC-bearing stash" "rm " "$READLINE_LINE"
# (2) A planted NEWLINE (the auto-submit RCE vector) can NEVER reach the buffer: `read` terminates
# the field at the newline, so the spliced READLINE_LINE is single-line — no accept-line trigger.
# (In production the worker's pipeline already rejected any control char upstream; this is the
# cross-process belt-and-suspenders that makes the newline vector structurally impossible.)
READLINE_LINE="rm "; READLINE_POINT=3
_nh_stash 5 0 3 $'rm -rf /\n'
_nh_accept
case "$READLINE_LINE" in *$'\n'*) _nl=yes ;; *) _nl=no ;; esac
check "accept: planted newline never reaches buffer" "no" "$_nl"

# ======================================================================================
# Cursor-motion + delete edit logic (touch only READLINE_LINE/POINT + the stash/gen files, no real
# tty — _nh_tty_write is stubbed above). _nh_dispatch is stubbed to a no-op so _nh_backward_delete's
# trailing re-query can't attempt IPC (or spawn a daemon/worker) during the test.
# ======================================================================================
_nh_dispatch() { :; }

# forward_or_accept, NO stash -> reimplements forward-char (advance one CHAR, byte-correct).
rm -f "$_nh_run_dir/stash"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=2
_nh_forward_or_accept
check "forward moves one ascii char"            3 "$READLINE_POINT"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=3   # cursor before the 2-byte é
_nh_forward_or_accept
check "forward crosses multibyte char (3->5)"   5 "$READLINE_POINT"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=5   # at EOL, no stash
_nh_forward_or_accept
check "forward no-op at EOL without stash"       5 "$READLINE_POINT"
# Live stash at EOL -> accept; off-EOL -> move (the EOL re-check), leaving the buffer intact.
_nh_gen=7
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 7 0 3 "git status"
_nh_forward_or_accept
check "forward accepts at EOL with stash" "git status" "$READLINE_LINE"
READLINE_LINE="git status"; READLINE_POINT=3      # cursor mid-line, stash live
_nh_stash 7 0 3 "git status"
_nh_forward_or_accept
check "forward does NOT accept off-EOL"  "git status" "$READLINE_LINE"
check "forward advanced cursor off-EOL"   4           "$READLINE_POINT"

# _nh_tab_widget (opt-in Tab accept): same stash+EOL gate as forward_or_accept via _nh_stash_ready,
# but accept-or-NOOP (no forward-char fallback). Covers the security-relevant opt-in accept path.
_nh_gen=7
READLINE_LINE="git"; READLINE_POINT=3
_nh_stash 7 0 3 "git status"
_nh_tab_widget
check "tab accepts at EOL with stash" "git status" "$READLINE_LINE"
READLINE_LINE="git status"; READLINE_POINT=3       # cursor mid-line, stash live -> no accept
_nh_stash 7 0 3 "git status"
_nh_tab_widget
check "tab no-op off-EOL" "git status" "$READLINE_LINE"
rm -f "$_nh_run_dir/stash"                         # no stash -> no-op (does NOT native-complete)
READLINE_LINE="git"; READLINE_POINT=3
_nh_tab_widget
check "tab no-op without stash" "git" "$READLINE_LINE"

# _nh_dismiss (Escape): drops the stash + bumps the generation, never touching the buffer.
_nh_gen=7
_nh_stash 7 0 3 "git status"
READLINE_LINE="git"; READLINE_POINT=3
_nh_dismiss
check "dismiss dropped the stash" "" "$([[ -f "$_nh_run_dir/stash" ]] && echo present)"
check "dismiss bumped the gen"    8    "$_nh_gen"
check "dismiss left buffer alone" "git" "$READLINE_LINE"

# Bound cursor MOTIONS (Left/Home/End): clear the ghost (drops the stash) + move, multibyte-safe.
_nh_stash 7 0 3 "x"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=5
_nh_cursor_left
check "cursor_left crosses multibyte (5->3)" 3 "$READLINE_POINT"
check "cursor_left dropped the stash" "" "$([[ -f "$_nh_run_dir/stash" ]] && echo present)"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=3
_nh_cursor_home
check "cursor_home to BOL" 0 "$READLINE_POINT"
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=0
_nh_cursor_end
check "cursor_end to EOL (bytes)" 5 "$READLINE_POINT"

# backward_delete removes a WHOLE codepoint (never half a multibyte char).
READLINE_LINE=$'caf\xc3\xa9'; READLINE_POINT=5
_nh_backward_delete
check "backspace removes whole multibyte char" "caf" "$READLINE_LINE"
check "backspace cursor after delete (bytes)"   3    "$READLINE_POINT"
READLINE_LINE="git"; READLINE_POINT=3
_nh_backward_delete
check "backspace removes ascii char" "gi" "$READLINE_LINE"
check "backspace ascii cursor"        2   "$READLINE_POINT"
READLINE_LINE="git"; READLINE_POINT=0
_nh_backward_delete
check "backspace at pos 0 is a no-op" "git" "$READLINE_LINE"

# ======================================================================================
# Config: precedence (default < file < env) + debounce clamp. Re-sources the plugin under
# different config/env to exercise the source-time load + override + clamp code.
# ======================================================================================
reload() { source "$_nh_plugin"; }   # re-runs config load + env override + clamp

# 1. Defaults (empty temp config dir, env unset).
unset NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_TAB_ACCEPT
rm -f "$_nh_tmpcfg/nighthawk/config.toml"
reload
check "cfg default arrow"      "->"  "$_nh_hint_arrow"
check "cfg default debounce"   "200" "$_nh_debounce_ms"
check "cfg default debug"      "0"   "$_nh_debug"
check "cfg default tab_accept" "0"   "$_nh_tab_accept"

# 2. File overrides default.
mkdir -p "$_nh_tmpcfg/nighthawk"
cat > "$_nh_tmpcfg/nighthawk/config.toml" <<'TOML'
# comment
[other]
hint_arrow = "XX"
[plugin]
hint_arrow = "=>"
debounce_ms = 350
debug = true
tab_accept = true
TOML
reload
check "cfg file arrow"      "=>"  "$_nh_hint_arrow"
check "cfg file debounce"   "350" "$_nh_debounce_ms"
check "cfg file debug"      "1"   "$_nh_debug"
check "cfg file tab_accept" "1"   "$_nh_tab_accept"

# 3. Env overrides file (tab_accept: file says true, env forces 0).
export NIGHTHAWK_HINT_ARROW=">>" NIGHTHAWK_DEBOUNCE_MS=99 NIGHTHAWK_DEBUG=1 NIGHTHAWK_TAB_ACCEPT=0
reload
check "cfg env arrow"      ">>" "$_nh_hint_arrow"
check "cfg env debounce"   "99" "$_nh_debounce_ms"
check "cfg env tab_accept" "0"  "$_nh_tab_accept"

# 4. Clamp: non-digit env resets to default; leading-zero is base-10 (not octal).
export NIGHTHAWK_DEBOUNCE_MS=foo
reload
check "cfg clamp non-digit -> 200" "200" "$_nh_debounce_ms"
export NIGHTHAWK_DEBOUNCE_MS=0200
reload
check "cfg clamp leading-zero base10" "200" "$_nh_debounce_ms"
unset NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_TAB_ACCEPT

# --- summary ---
rm -rf "$_nh_tmpcfg" "$_nh_test_rundir"
printf 'helpers.test.bash: %d passed, %d failed\n' "$_nh_pass" "$_nh_fail"
(( _nh_fail == 0 ))
