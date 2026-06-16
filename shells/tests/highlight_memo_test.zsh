#!/usr/bin/env zsh
# Unit tests for _nh_strip_highlights in shells/nighthawk.zsh — the single chokepoint that
# removes ONLY this plugin's region_highlight entries (issue #10). The old code popped the last
# N entries positionally, which stole a co-resident highlighter's (e.g. zsh-syntax-highlighting)
# entries whenever they were appended after ours. The fix tags our entries with `memo=nighthawk`
# (zsh 5.9+) and removes by identity; on <=5.8 (no memo support) it falls back to the positional
# pop. This test drives BOTH branches regardless of the host zsh version by forcing _nh_memo.
#
# Hermetic source mirrors offsets.test.zsh: stub the ZLE builtins so widget/keymap registration
# is inert, isolate config to a temp dir.
#
# Run:  zsh shells/tests/highlight_memo_test.zsh
emulate -L zsh

# --- Hermetic source ---
zle()     { : }
bindkey() { : }

_nh_tmpcfg=$(mktemp -d)
export XDG_CONFIG_HOME=$_nh_tmpcfg
_nh_plugin="${0:A:h}/../nighthawk.zsh"
if [[ ! -r "$_nh_plugin" ]]; then
    print -u2 "highlight_memo_test.zsh: cannot read $_nh_plugin"
    rm -rf "$_nh_tmpcfg"
    exit 2
fi
source "$_nh_plugin"
rm -rf "$_nh_tmpcfg"

# Structural check: the chokepoint and its state must exist (guards against a rename).
if (( ! $+functions[_nh_strip_highlights] )); then
    print -u2 "highlight_memo_test.zsh: FAIL — _nh_strip_highlights not defined (renamed? deps missing?)"
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
# Join region_highlight with a '|' so order and content can be asserted as one string.
joined() { local IFS='|'; print -r -- "${region_highlight[*]}" }

# ====================================================================================
# MEMO branch (zsh 5.9+): remove our entries by identity, regardless of array position.
# Forced on so the branch is exercised even on a <=5.8 host. _nh_memo_token is set
# unconditionally at source time, so the tag/glob are valid here on any version.
# ====================================================================================
_nh_memo=1
_nh_memo_tag=" memo=$_nh_memo_token"

# Adversarial layout: ours are NOT at the tail, and a foreign entry sits BETWEEN two of ours.
# Includes the comma-style diff highlight and a foreign entry that ALSO uses memo=.
region_highlight=(
    "0 3 fg=green"                          # foreign, untagged (e.g. z-sy-h command)
    "5 10 fg=8 memo=nighthawk"              # ours: ghost  (NOT at tail)
    "4 8 fg=yellow memo=zsh-syntax-highlighting"  # foreign, memo-tagged by another plugin
    "12 14 fg=red,bold memo=nighthawk"      # ours: diff delete (comma in style)
    "15 16 fg=8 memo=nighthawk"             # ours: diff insert
    "20 25 fg=cyan"                         # foreign, untagged (interleaved AFTER ours)
    "30 40 fg=8 memo=nighthawk-companion"   # foreign look-alike — must NOT be stripped (anchor)
)
_nh_has_highlight=3
_nh_strip_highlights
check "memo: survivors + order preserved" \
    "0 3 fg=green|4 8 fg=yellow memo=zsh-syntax-highlighting|20 25 fg=cyan|30 40 fg=8 memo=nighthawk-companion" \
    "$(joined)"
check "memo: no ours remain"        "" "${region_highlight[(r)* memo=nighthawk]}"
check "memo: counter reset"          0 "$_nh_has_highlight"

# Removing all of ours from an all-ours array yields a truly empty array (not [""]).
region_highlight=( "1 2 fg=8 memo=nighthawk" "3 4 fg=8 memo=nighthawk" )
_nh_has_highlight=2
_nh_strip_highlights
check "memo: all-ours -> empty array" 0 "${#region_highlight}"

# No entries of ours present -> foreign array untouched.
region_highlight=( "0 1 fg=green" "2 3 fg=red" )
_nh_has_highlight=0
_nh_strip_highlights
check "memo: none-ours untouched"     "0 1 fg=green|2 3 fg=red" "$(joined)"

# setopt-independence: :# is parameter expansion, not filename globbing, so glob options must
# not change the result. Lock that claim explicitly rather than assuming it.
setopt LOCAL_OPTIONS KSH_GLOB EXTENDED_GLOB NO_GLOB
region_highlight=( "0 3 fg=green" "5 10 fg=8 memo=nighthawk" )
_nh_has_highlight=1
_nh_strip_highlights
check "memo: setopt-independent"      "0 3 fg=green" "$(joined)"
unsetopt KSH_GLOB EXTENDED_GLOB NO_GLOB

# ====================================================================================
# FALLBACK branch (zsh <=8.8, no memo): pop the last _nh_has_highlight entries.
# Forced regardless of host. Positional by necessity, so our entries must be at the TAIL
# (which is the real-world layout when no co-resident plugin appended after us).
# ====================================================================================
_nh_memo=0
_nh_memo_tag=""

# Single ghost entry at the tail.
region_highlight=( "0 3 fg=green" "5 10 fg=8" )
_nh_has_highlight=1
_nh_strip_highlights
check "fallback: pop 1 from tail"     "0 3 fg=green" "$(joined)"
check "fallback: counter reset"        0 "$_nh_has_highlight"

# Multi-entry diff: count must equal entries appended; all of ours popped.
region_highlight=( "0 3 fg=green" "5 6 fg=red,bold" "6 7 fg=8" "7 8 fg=8" )
_nh_has_highlight=3
_nh_strip_highlights
check "fallback: pop N(diff) from tail" "0 3 fg=green" "$(joined)"

# Underflow guard: count larger than the array must not error or wrap.
region_highlight=( "0 3 fg=green" )
_nh_has_highlight=5
_nh_strip_highlights
check "fallback: underflow-safe"       0 "${#region_highlight}"

# Empty array + zero count: no-op, no error.
region_highlight=()
_nh_has_highlight=0
_nh_strip_highlights
check "fallback: empty/zero no-op"     0 "${#region_highlight}"

# --- summary ---
print -r -- "highlight_memo_test.zsh: $_nh_pass passed, $_nh_fail failed"
(( _nh_fail == 0 ))
