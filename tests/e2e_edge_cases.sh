#!/usr/bin/env bash
# Additional edge case tests for fuzzy matching
# Run in WSL: bash tests/e2e_edge_cases.sh

set -euo pipefail

NH="./target/debug/nh"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local input="$2"
    local expected="$3"
    local negate="${4:-}"

    local output
    output=$($NH complete "$input" 2>&1) || true

    if [[ "$negate" == "!" ]]; then
        if echo "$output" | grep -qE -- "$expected"; then
            echo "FAIL: $desc"
            echo "  input:    '$input'"
            echo "  expected: NOT matching /$expected/"
            echo "  got:      $output"
            FAIL=$((FAIL + 1))
        else
            echo "PASS: $desc"
            PASS=$((PASS + 1))
        fi
    else
        if echo "$output" | grep -qE -- "$expected"; then
            echo "PASS: $desc"
            PASS=$((PASS + 1))
        else
            echo "FAIL: $desc"
            echo "  input:    '$input'"
            echo "  expected: /$expected/"
            echo "  got:      $output"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "=== Edge Case E2E Tests ==="
echo ""

# --- Start daemon ---
$NH stop 2>/dev/null || true
sleep 0.3
$NH start
sleep 0.5

echo ""

# --- 1. Double fuzzy: command + subcommand both misspelled ---
check "Double fuzzy: gti chekout → git checkout" \
    "gti chekout" "git checkout"

check "Double fuzzy: gti chekcout → git checkout (transposition)" \
    "gti chekcout" "git checkout"

# --- 2. Fuzzy command + trailing space ---
check "Fuzzy cmd + space: gti → lists git subcommands" \
    "gti " "git "

# --- 3. Too many edits (dist > 2) → no match ---
check "Too many edits: git xyzabc → no suggestions" \
    "git xyzabc" "no suggestions"

check "Too many edits on command: abc checkout → no suggestions" \
    "abc checkout" "no suggestions"

# --- 4. Short tokens: no fuzzy ---
check "2-char prefix: git co → commit" \
    "git co" "commit"

check "2-char gibberish: git zz → no suggestions" \
    "git zz" "no suggestions"

check "1-char: git x → no suggestions" \
    "git x" "no suggestions"

# --- 5. Fuzzy aliases ---
check "Fuzzy alias: git swtich → switch" \
    "git swtich" "switch"

# --- 6. Used flag dedup with fuzzy ---
check "Used flag + fuzzy: git --verbose --vrebose → no dup" \
    "git --verbose --vrebose" "no suggestions"

# --- 7. Boundary inputs ---
check "Empty input → no suggestions" \
    "" "no suggestions"

check "Just command no space: git → no suggestions" \
    "git" "no suggestions"

check "Fuzzy cmd no space: gti → no suggestions" \
    "gti" "no suggestions"

# --- 8. Extra whitespace handling ---
check "Extra spaces: git  chekout → checkout" \
    "git  chekout" "checkout"

# --- 9. Fuzzy + flag stacking coexistence ---
check "Stacking still works: ls -la → extensions" \
    "ls -la" "-la."

check "Stacking invalid unchanged: ls -lz → no suggestions" \
    "ls -lz" "no suggestions"

# --- Stop daemon ---
echo ""
$NH stop

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && echo "All edge case tests passed!" || exit 1
