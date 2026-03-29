#!/usr/bin/env bash
# End-to-end tests for fuzzy matching (Issue #3)
# Run in WSL: bash tests/e2e_fuzzy.sh

set -euo pipefail

NH="./target/debug/nh"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local input="$2"
    local expected="$3"  # grep pattern to match in output
    local negate="${4:-}"  # "!" to expect no match

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

echo "=== Fuzzy Matching E2E Tests ==="
echo ""

# --- Start daemon ---
$NH stop 2>/dev/null || true
sleep 0.3
$NH start
sleep 0.5

echo ""

# --- 1. Prefix matching still works (no regression) ---
check "Prefix: git ch → checkout" \
    "git ch" "checkout"

check "Prefix: git --ver → --version" \
    "git --ver" "version"

check "Prefix: curl -X P → POST, PUT" \
    "curl -X P" "POST"

# --- 2. Flag stacking still works (no regression) ---
check "Flag stacking: ls -l → extensions" \
    "ls -l" "-la"

check "Flag stacking: ls -la → extensions" \
    "ls -la" "-la."

# --- 3. Fuzzy subcommand matching ---
check "Fuzzy sub (deletion): git chekout → checkout" \
    "git chekout" "checkout"

check "Fuzzy sub (transposition): git chekcout → checkout" \
    "git chekcout" "checkout"

check "Fuzzy sub (substitution): git chackout → checkout" \
    "git chackout" "checkout"

# --- 4. Fuzzy option matching (--long options only) ---
check "Fuzzy option: git --verison → --version" \
    "git --verison" "version"

check "Fuzzy option: ls --colro → --color" \
    "ls --colro" "color"

# --- 5. No fuzzy on short tokens ---
# git co → prefix matches "commit", "config", etc. (prefix, not fuzzy)
# Fuzzy rejection only means no fuzzy fallback — prefix still works
check "Short token prefix: git co → commit (prefix match, not fuzzy)" \
    "git co" "commit"

# --- 6. No fuzzy interference with flag stacking ---
check "Stacked invalid: ls -lz → no suggestions" \
    "ls -lz" "no suggestions"

# --- 7. Fuzzy command-name resolution ---
check "Fuzzy command + prefix: gti ch → git checkout" \
    "gti ch" "git checkout"

check "Fuzzy command + prefix: gti che → git checkout + git cherry-pick" \
    "gti che" "git checkout"

# --- 8. Arg-value suggestions still work ---
check "Arg values: curl -X → GET" \
    "curl -X " "GET"

# --- Stop daemon ---
echo ""
$NH stop

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && echo "All tests passed!" || exit 1
