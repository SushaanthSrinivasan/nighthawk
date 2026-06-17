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
# Requires the same tools the plugin does (bash, socat, jq on PATH); if they're missing the
# plugin's dep-check returns early and the helpers stay undefined — caught below as a loud
# failure, exactly like offsets.test.zsh.
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
for fn in _nh_load_config _nh_log _nh_has_ctrl_char _nh_byte_to_char _nh_char_to_byte \
          _nh_json_escape _nh_build_request _nh_parse_response _nh_decide_render \
          _nh_compute_suggestion; do
    if ! declare -F "$fn" >/dev/null; then
        echo "helpers.test.bash: FAIL — $fn not defined after sourcing plugin (renamed? deps missing?)" >&2
        rm -rf "$_nh_tmpcfg"
        exit 2
    fi
done

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
check "esc plain passthrough" 'git 中' "$(_nh_json_escape 'git 中')"
check "build request" '{"input":"git st","cursor":6,"cwd":"/home/u","shell":"bash"}' \
    "$(_nh_build_request 'git st' 6 '/home/u')"
check "build request escapes quote" '{"input":"echo \"hi\"","cursor":9,"cwd":"/w","shell":"bash"}' \
    "$(_nh_build_request 'echo "hi"' 9 '/w')"

# ======================================================================================
# Response parse (eval-able assignments; locals defaulted before eval)
# ======================================================================================
parse_into() {  # parse_into <json>  -> sets text/replace_start/replace_end/diff_ops_present
    text='' replace_start='' replace_end='' diff_ops_present=0
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
parse_into 'not json at all'
check "parse malformed -> no text (not stale)" "" "$text"

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

# End-to-end pipeline through parse + reject + convert + validate + decide:
check "pipeline ghost" $'ghost\t status' \
    "$(_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')"
check "pipeline hint (divergent)" $'hint\t -> git status' \
    "$(_nh_compute_suggestion 'gti' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')"
# Control char in suggestion -> rejected (no output).
check "pipeline rejects ctrl-char suggestion" "" \
    "$(_nh_compute_suggestion 'rm ' '{"suggestions":[{"text":"rm -rf /\n","replace_start":0,"replace_end":3}]}')"
# Malformed range (null) -> no output.
check "pipeline rejects null range" "" \
    "$(_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status"}]}')"

# ======================================================================================
# Config: precedence (default < file < env) + debounce clamp. Re-sources the plugin under
# different config/env to exercise the source-time load + override + clamp code.
# ======================================================================================
reload() { source "$_nh_plugin"; }   # re-runs config load + env override + clamp

# 1. Defaults (empty temp config dir, env unset).
unset NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG
rm -f "$_nh_tmpcfg/nighthawk/config.toml"
reload
check "cfg default arrow"    "->" "$_nh_hint_arrow"
check "cfg default debounce" "200" "$_nh_debounce_ms"
check "cfg default debug"    "0"  "$_nh_debug"

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
TOML
reload
check "cfg file arrow"    "=>"  "$_nh_hint_arrow"
check "cfg file debounce" "350" "$_nh_debounce_ms"
check "cfg file debug"    "1"   "$_nh_debug"

# 3. Env overrides file.
export NIGHTHAWK_HINT_ARROW=">>" NIGHTHAWK_DEBOUNCE_MS=99 NIGHTHAWK_DEBUG=1
reload
check "cfg env arrow"    ">>" "$_nh_hint_arrow"
check "cfg env debounce" "99" "$_nh_debounce_ms"

# 4. Clamp: non-digit env resets to default; leading-zero is base-10 (not octal).
export NIGHTHAWK_DEBOUNCE_MS=foo
reload
check "cfg clamp non-digit -> 200" "200" "$_nh_debounce_ms"
export NIGHTHAWK_DEBOUNCE_MS=0200
reload
check "cfg clamp leading-zero base10" "200" "$_nh_debounce_ms"
unset NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG

# --- summary ---
rm -rf "$_nh_tmpcfg"
printf 'helpers.test.bash: %d passed, %d failed\n' "$_nh_pass" "$_nh_fail"
(( _nh_fail == 0 ))
