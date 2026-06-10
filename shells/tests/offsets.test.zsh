#!/usr/bin/env zsh
# Unit tests for the _nh_byte_to_char / _nh_char_to_byte helpers in shells/nighthawk.zsh
# (issue: the daemon speaks UTF-8 BYTE offsets, zsh subscripts index in locale units —
# characters under a UTF-8 locale — so accept mis-replaces on CJK/emoji without conversion).
#
# Hermetic by sourcing the plugin with the interactive ZLE builtins (zle/bindkey) stubbed
# to no-ops and config isolated to a temp dir, so none of the plugin's side effects (widget
# registration, keymap binding, user config) run. This is the zsh analogue of how
# shells/tests/converters.Tests.ps1 AST-extracts just the PowerShell $byteToChar.
#
# Requires the same tools the plugin does (zsh, socat, jq on PATH); if they're missing the
# plugin returns early and the helpers won't be defined — caught below as a loud failure.
#
# Run:  zsh shells/tests/offsets.test.zsh
emulate -L zsh

# --- Hermetic source ---
# Shadow the ZLE builtins so `zle -N` / `bindkey` registration is inert during sourcing.
zle()     { : }
bindkey() { : }

_nh_tmpcfg=$(mktemp -d)
export XDG_CONFIG_HOME=$_nh_tmpcfg
_nh_plugin="${0:A:h}/../nighthawk.zsh"
if [[ ! -r "$_nh_plugin" ]]; then
    print -u2 "offsets.test.zsh: cannot read $_nh_plugin"
    rm -rf "$_nh_tmpcfg"
    exit 2
fi
source "$_nh_plugin"
rm -rf "$_nh_tmpcfg"

# Structural check: the helpers must exist (guards against a rename, like the PS test's
# "was it renamed?" throw — the sourcing above is the precondition that makes this sound).
if (( ! $+functions[_nh_byte_to_char] || ! $+functions[_nh_char_to_byte] )); then
    print -u2 "offsets.test.zsh: FAIL — offset helpers not defined after sourcing plugin (renamed? deps missing?)"
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

# Test data built from CODE POINTS, not literal glyphs, so it survives file-encoding
# mishaps regardless of how the file is checked out (matching converters.Tests.ps1's
# rationale). Widths: a=1B  U+00E9(e-acute)=2B  U+4E2D(CJK)=3B  U+1F600(emoji)=4B  U+00E9=2B
#   => byte boundaries 0,1,3,6,10,12 ; 5 char units.
S=$'\u0061\u00e9\u4e2d\U0001f600\u00e9'

# --- ASCII (byte == char identity) ---
A="git checkout"
check "ascii b2c 0"        0  "$(_nh_byte_to_char "$A" 0)"
check "ascii b2c 4"        4  "$(_nh_byte_to_char "$A" 4)"
check "ascii b2c 12 (EOL)" 12 "$(_nh_byte_to_char "$A" 12)"
check "ascii c2b 4"        4  "$(_nh_char_to_byte "$A" 4)"
check "ascii c2b 12 (EOL)" 12 "$(_nh_char_to_byte "$A" 12)"

# --- byte_to_char on code-point boundaries (2/3/4-byte sequences, each -> one char) ---
check "b2c 0"             0 "$(_nh_byte_to_char "$S" 0)"
check "b2c 1 (after 1B)"  1 "$(_nh_byte_to_char "$S" 1)"
check "b2c 3 (after 2B)"  2 "$(_nh_byte_to_char "$S" 3)"
check "b2c 6 (after 3B)"  3 "$(_nh_byte_to_char "$S" 6)"
check "b2c 10 (after 4B)" 4 "$(_nh_byte_to_char "$S" 10)"
check "b2c 12 (EOL)"      5 "$(_nh_byte_to_char "$S" 12)"

# --- mid-sequence rejections (fail-closed -> -1) ---
check "b2c 2  (mid 2-byte seq)" -1 "$(_nh_byte_to_char "$S" 2)"
check "b2c 4  (mid 3-byte seq)" -1 "$(_nh_byte_to_char "$S" 4)"
check "b2c 5  (mid 3-byte seq)" -1 "$(_nh_byte_to_char "$S" 5)"
check "b2c 7  (mid 4-byte seq)" -1 "$(_nh_byte_to_char "$S" 7)"
check "b2c 8  (mid 4-byte seq)" -1 "$(_nh_byte_to_char "$S" 8)"
check "b2c 9  (mid 4-byte seq)" -1 "$(_nh_byte_to_char "$S" 9)"

# --- bounds & degenerate inputs ---
check "b2c -1 (negative)"    -1 "$(_nh_byte_to_char "$S" -1)"
check "b2c 13 (past end)"    -1 "$(_nh_byte_to_char "$S" 13)"
check "b2c empty, off 0"      0 "$(_nh_byte_to_char "" 0)"
check "b2c empty, off 1"     -1 "$(_nh_byte_to_char "" 1)"

# --- char_to_byte inverse on boundaries ---
check "c2b 0"  0  "$(_nh_char_to_byte "$S" 0)"
check "c2b 1"  1  "$(_nh_char_to_byte "$S" 1)"
check "c2b 2"  3  "$(_nh_char_to_byte "$S" 2)"
check "c2b 3"  6  "$(_nh_char_to_byte "$S" 3)"
check "c2b 4"  10 "$(_nh_char_to_byte "$S" 4)"
check "c2b 5"  12 "$(_nh_char_to_byte "$S" 5)"
check "c2b past-end clamps" 12 "$(_nh_char_to_byte "$S" 99)"
check "c2b negative -> 0"    0 "$(_nh_char_to_byte "$S" -3)"

# --- round-trip: byte_to_char(char_to_byte(i)) == i over every boundary ---
local i b
for i in 0 1 2 3 4 5; do
    b=$(_nh_char_to_byte "$S" $i)
    check "roundtrip char $i (byte $b)" $i "$(_nh_byte_to_char "$S" $b)"
done

# --- multi-codepoint ZWJ grapheme: each code point is a separate zsh char; the
# per-code-point walk must round-trip just like single-code-point chars (locks the
# contract that we count UTF-8 bytes per code point, matching the byte-native daemon).
# U+1F468 ZWJ(U+200D) U+1F469 ZWJ U+1F467 = man/woman/girl family = 5 code points. ---
local FAM=$'\U0001f468\u200d\U0001f469\u200d\U0001f467'
for (( i = 0; i <= ${#FAM}; i++ )); do
    b=$(_nh_char_to_byte "$FAM" $i)
    check "ZWJ roundtrip char $i (byte $b)" $i "$(_nh_byte_to_char "$FAM" $b)"
done

# --- summary ---
print -r -- "offsets.test.zsh: $_nh_pass passed, $_nh_fail failed"
(( _nh_fail == 0 ))
