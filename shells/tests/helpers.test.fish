#!/usr/bin/env fish
# Unit tests for the pure helpers in shells/nighthawk.fish.
#
# The fish analogue of shells/tests/helpers.test.bash, trimmed to the contracts that actually
# survive in fish (the bash harness's octal/zero-pad/CRLF/BASH_REMATCH rows test bash-specific
# hazards that don't exist here). Hermetic: config is isolated to a temp XDG_CONFIG_HOME and the
# NIGHTHAWK_* env overrides are unset before sourcing.
#
# Requires fish + socat + jq + a UTF-8 locale (run on Linux/WSL). The pure helpers are defined
# ABOVE the plugin's dep-check, so they exist after sourcing even on a depless box; what fails
# there are the jq-backed parse/pipeline rows.
#
# Run:  fish shells/tests/helpers.test.fish

# --- Hermetic source ---
set -gx XDG_CONFIG_HOME (mktemp -d)
set -e NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_TAB_ACCEPT NIGHTHAWK_SOCKET

set -l here (status dirname)
set -g _nh_plugin "$here/../nighthawk.fish"
if not test -r "$_nh_plugin"
    echo "helpers.test.fish: cannot read $_nh_plugin" >&2
    exit 2
end
source "$_nh_plugin"

# Structural check: the helpers must exist after sourcing (guards a rename / missing deps).
for fn in _nh_load_config _nh_ms_to_sec _nh_log _nh_has_ctrl_char _nh_cp_width _nh_byte_to_char \
        _nh_char_to_byte _nh_eol_bytes _nh_build_request _nh_parse_response _nh_decide_render \
        _nh_compute_suggestion _nh_clear_seq _nh_paint_seq _nh_render_seq _nh_tty_write \
        _nh_clear_ghost _nh_paint_ghost _nh_input_changed \
        _nh_state_init _nh_cleanup _nh_bump_gen _nh_ensure_daemon _nh_request _nh_dispatch _nh_worker \
        _nh_accept_splice _nh_keypress _nh_stash_ready _nh_accept _nh_forward_or_accept _nh_tab_widget \
        _nh_dismiss _nh_cursor_left _nh_cursor_home _nh_cursor_end
    if not functions -q $fn
        echo "helpers.test.fish: FAIL — $fn not defined after sourcing plugin (renamed? deps missing?)" >&2
        exit 2
    end
end

# --- Assertion harness ---
set -g _nh_pass 0
set -g _nh_fail 0
function check # check <desc> <expected> <actual>
    if test "$argv[2]" = "$argv[3]"
        set _nh_pass (math $_nh_pass + 1)
    else
        set _nh_fail (math $_nh_fail + 1)
        printf "FAIL: %s — expected '%s' got '%s'\n" "$argv[1]" "$argv[2]" "$argv[3]"
    end
end

# ======================================================================================
# Offset converters. a=U+0061(1B) é=U+00E9(2B) 中=U+4E2D(3B) 😀=U+1F600(4B) é=U+00E9(2B)
#   => byte boundaries 0,1,3,6,10,12 ; 5 code-point units.
# ======================================================================================
set -l S aé中😀é

# ASCII (byte == char identity, fast-path)
set -l A "git checkout"
check "ascii b2c 0" 0 (_nh_byte_to_char "$A" 0)
check "ascii b2c 4" 4 (_nh_byte_to_char "$A" 4)
check "ascii b2c 12 (EOL)" 12 (_nh_byte_to_char "$A" 12)
check "ascii c2b 4" 4 (_nh_char_to_byte "$A" 4)
check "ascii c2b 12 (EOL)" 12 (_nh_char_to_byte "$A" 12)

# byte_to_char on code-point boundaries (2/3-byte sequences)
check "b2c 0" 0 (_nh_byte_to_char "$S" 0)
check "b2c 1 (after 1B)" 1 (_nh_byte_to_char "$S" 1)
check "b2c 3 (after 2B)" 2 (_nh_byte_to_char "$S" 3)
check "b2c 6 (after 3B)" 3 (_nh_byte_to_char "$S" 6)
check "b2c 12 (EOL)" 5 (_nh_byte_to_char "$S" 12)

# mid-sequence rejections (fail-closed -> -1)
check "b2c 2 (mid 2-byte)" -1 (_nh_byte_to_char "$S" 2)
check "b2c 4 (mid 3-byte)" -1 (_nh_byte_to_char "$S" 4)
check "b2c 5 (mid 3-byte)" -1 (_nh_byte_to_char "$S" 5)

# bounds & degenerate inputs
check "b2c -1 (negative)" -1 (_nh_byte_to_char "$S" -1)
check "b2c 13 (past end)" -1 (_nh_byte_to_char "$S" 13)
check "b2c empty, off 0" 0 (_nh_byte_to_char "" 0)
check "b2c empty, off 1" -1 (_nh_byte_to_char "" 1)

# char_to_byte inverse on boundaries
check "c2b 0" 0 (_nh_char_to_byte "$S" 0)
check "c2b 1" 1 (_nh_char_to_byte "$S" 1)
check "c2b 2" 3 (_nh_char_to_byte "$S" 2)
check "c2b 3" 6 (_nh_char_to_byte "$S" 3)
check "c2b 5" 12 (_nh_char_to_byte "$S" 5)
check "c2b past-end clamps" 12 (_nh_char_to_byte "$S" 99)
check "c2b negative -> 0" 0 (_nh_char_to_byte "$S" -3)

# eol_bytes: byte length of the whole string
check "eol_bytes ascii" 12 (_nh_eol_bytes "$A")
check "eol_bytes multibyte" 12 (_nh_eol_bytes "$S")
check "eol_bytes empty" 0 (_nh_eol_bytes "")

# 4-byte (astral) coverage — probe-gated on fish counting it as ONE code point.
if test (string length -- 😀) -eq 1
    check "b2c 10 (after 4B)" 4 (_nh_byte_to_char "$S" 10)
    check "b2c 7 (mid 4-byte)" -1 (_nh_byte_to_char "$S" 7)
    check "b2c 8 (mid 4-byte)" -1 (_nh_byte_to_char "$S" 8)
    check "b2c 9 (mid 4-byte)" -1 (_nh_byte_to_char "$S" 9)
    check "c2b 4 (astral)" 10 (_nh_char_to_byte "$S" 4)
else
    echo "NOTE: 😀 counts as "(string length -- 😀)" code points on this fish — 4-byte rows skipped"
end

# ======================================================================================
# Control-char guard (fail-closed). Returns status 0 == HAS control char.
# ======================================================================================
_nh_has_ctrl_char "git status"; check "ctrl: clean cmd" 1 $status
_nh_has_ctrl_char (printf 'ls\nrm' | string collect -N); check "ctrl: newline rejected" 0 $status
_nh_has_ctrl_char (printf 'a\x1bb' | string collect -N); check "ctrl: ESC rejected" 0 $status
_nh_has_ctrl_char (printf 'a\x7f' | string collect -N); check "ctrl: DEL rejected" 0 $status
_nh_has_ctrl_char (printf 'a\tb' | string collect -N); check "ctrl: TAB rejected" 0 $status
# C1 controls: 0x9b = 8-bit CSI. Both the raw byte (fish stores it as U+F69B passthrough) and the
# UTF-8-encoded code point U+009B must be rejected — a code-point-only \x80-\x9f class misses the raw form.
_nh_has_ctrl_char (printf 'a\x9bb' | string collect -N); check "ctrl: raw C1 0x9b (CSI byte) rejected" 0 $status
_nh_has_ctrl_char (printf 'a\xc2\x9bb' | string collect -N); check "ctrl: encoded C1 U+009B rejected" 0 $status
# Bidi / zero-width formatters (Trojan Source, CVE-2021-42574) — display-spoofing, must be rejected.
_nh_has_ctrl_char (printf 'cd \xe2\x80\xaednetni' | string collect -N); check "ctrl: bidi RLO U+202E rejected" 0 $status
_nh_has_ctrl_char (printf 'a\xe2\x80\x8bb' | string collect -N); check "ctrl: zero-width ZWSP U+200B rejected" 0 $status
_nh_has_ctrl_char "echo 中"; check "ctrl: multibyte accepted" 1 $status
_nh_has_ctrl_char "echo 😀"; check "ctrl: astral emoji accepted" 1 $status

# ======================================================================================
# Request build (jq escapes; "shell":"fish")
# ======================================================================================
check "build request" '{"input":"git st","cursor":6,"cwd":"/home/u","shell":"fish"}' \
    (_nh_build_request 'git st' 6 '/home/u')
check "build request escapes quote" '{"input":"echo \"hi\"","cursor":9,"cwd":"/w","shell":"fish"}' \
    (_nh_build_request 'echo "hi"' 9 '/w')

# ======================================================================================
# Response parse (TAB record: rstart, rend, diff_flag, text). text LAST.
# ======================================================================================
function parse_field # parse_field <json> <1-based index> -> echoes that field
    set -l parsed (_nh_parse_response $argv[1] | string collect -N)
    set -l fields (string split -m 3 \t -- $parsed)
    test (count $fields) -ge $argv[2]; and echo $fields[$argv[2]]
end
check "parse rstart" 0 (parse_field '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}' 1)
check "parse rend" 3 (parse_field '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}' 2)
check "parse no diff" 0 (parse_field '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}' 3)
check "parse text" "git status" (parse_field '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}' 4)
check "parse diff present" 1 (parse_field '{"suggestions":[{"text":"grep","replace_start":0,"replace_end":2,"diff_ops":[{"op":"keep","ch":"g"}]}]}' 3)
check "parse empty -> no text" "" (parse_field '{"suggestions":[]}' 4)

# ======================================================================================
# Decision logic
# ======================================================================================
check "decide ghost (prefix)" (printf 'ghost\t status') (_nh_decide_render 'git' 'git status' 0 0)
check "decide hint (divergent)" (printf 'hint\t -> git status') (_nh_decide_render 'gti' 'git status' 0 0)
check "decide hint (diff)" (printf 'hint\t -> git status') (_nh_decide_render 'git' 'git status' 0 1)
set -l got (_nh_decide_render 'git' 'git status' -1 0)
check "decide guards rstart=-1" "" "$got"
set got (_nh_decide_render 'git' '' 0 0)
check "decide empty text" "" "$got"
set got (_nh_decide_render 'git status' 'git status' 0 0)
check "decide empty when fully typed" "" "$got"
set got (_nh_decide_render 'git' 'git status' 99 0)
check "decide empty when rstart>blen" "" "$got"

# ======================================================================================
# Full pipeline (parse + reject + convert + validate + decide -> 5-field record)
# ======================================================================================
check "pipeline ghost" (printf 'ghost\t status\t0\t3\tgit status') \
    (_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')
check "pipeline hint (divergent)" (printf 'hint\t -> git status\t0\t3\tgit status') \
    (_nh_compute_suggestion 'gti' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')
# diff_ops present -> hint through the FULL pipeline. Pins the seam parse-field-3 (diff flag) -> decide
# arg-4: a prefix that WOULD render as a ghost is forced to a hint purely because diff_ops is present,
# so a wiring bug dropping/swapping the diff field would flip this back to a ghost record and fail here.
check "pipeline diff present -> hint" (printf 'hint\t -> git status\t0\t3\tgit status') \
    (_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3,"diff_ops":[{"op":"keep","ch":"g"}]}]}')
# Control char in suggestion (trailing-newline RCE vector) -> rejected (no output).
set got (_nh_compute_suggestion 'rm ' '{"suggestions":[{"text":"rm -rf /\n","replace_start":0,"replace_end":3}]}')
check "pipeline rejects ctrl-char suggestion" "" "$got"
# Malformed range (missing) -> no output.
set got (_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status"}]}')
check "pipeline rejects null range" "" "$got"
# Malformed JSON -> no output.
set got (_nh_compute_suggestion 'git' 'not json at all')
check "pipeline rejects malformed json" "" "$got"
# Multibyte: record carries the daemon's BYTE offsets while the prefix decision used CHAR offsets.
# "café" = 5 bytes / 4 chars; replace [0,5) with "café list" -> ghost " list", bstart/bend = 0/5.
check "pipeline multibyte carries byte offsets" (printf 'ghost\t list\t0\t5\tcafé list') \
    (_nh_compute_suggestion 'café' '{"suggestions":[{"text":"café list","replace_start":0,"replace_end":5}]}')
# Inverted range (replace_end < replace_start) -> fail-closed reject. Input isolates the
# `cend < cstart` guard: typed_len 0 < tlen, so decide_render WOULD emit a ghost if the guard
# were removed — only the guard makes this empty (a `text:"x"` here would reject earlier in
# decide_render instead, masking the guard).
set got (_nh_compute_suggestion 'git ' '{"suggestions":[{"text":"git status","replace_start":4,"replace_end":0}]}')
check "pipeline rejects inverted range" "" "$got"
# Append at EOL (rstart == blen, typed_len 0) -> whole text renders as ghost.
check "pipeline append-at-eol ghost" (printf 'ghost\tstatus\t4\t4\tstatus') \
    (_nh_compute_suggestion 'git ' '{"suggestions":[{"text":"status","replace_start":4,"replace_end":4}]}')

# 5-field tag parse: the split the H3 worker performs. text LAST so a leading-space display survives.
set -l rec (_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')
set -l f (string split -m 4 \t -- $rec)
check "tagparse kind" ghost $f[1]
check "tagparse display keeps leading space" " status" $f[2]
check "tagparse bstart" 0 $f[3]
check "tagparse bend" 3 $f[4]
check "tagparse text" "git status" $f[5]

# ======================================================================================
# _nh_ms_to_sec: locale-proof integer splice. 50->0.050 is the anti-10x guard; 0 floors to 10ms.
# ======================================================================================
check "ms_to_sec 200" 0.200 (_nh_ms_to_sec 200)
check "ms_to_sec 50 (no 10x)" 0.050 (_nh_ms_to_sec 50)
check "ms_to_sec 1500" 1.500 (_nh_ms_to_sec 1500)
check "ms_to_sec 10000" 10.000 (_nh_ms_to_sec 10000)
check "ms_to_sec 10" 0.010 (_nh_ms_to_sec 10)
check "ms_to_sec 0 -> floor" 0.010 (_nh_ms_to_sec 0)
check "ms_to_sec foo -> default 200" 0.200 (_nh_ms_to_sec foo)

# ======================================================================================
# H2 render primitives — PURE ANSI builders (clear / paint / render) + the input-change gate.
# $_nh_esc is the ESC byte the plugin sets at source time; expected sequences are rebuilt from it so
# the test pins the exact byte order (a swapped [0J/[u, or [K substituted for [0J, fails here).
# ======================================================================================
set -l ESC $_nh_esc

# clear_seq: save -> erase-to-end-of-SCREEN -> restore (ESC[0J, NOT ESC[K — a wrapped ghost).
check "clear_seq bytes" (printf '%s[s%s[0J%s[u' $ESC $ESC $ESC) (_nh_clear_seq)

# paint_seq: save -> gray -> text -> reset -> restore. A leading space in the display is preserved.
check "paint_seq bytes" (printf '%s[s%s[90m%s%s[0m%s[u' $ESC $ESC ' status' $ESC $ESC) (_nh_paint_seq ' status')
check "paint_seq empty -> nothing" "" (_nh_paint_seq '')
# Defense-in-depth: a control char in the display paints NOTHING (the last gate before the terminal).
set got (_nh_paint_seq (printf 'a\x1bb' | string collect -N))
check "paint_seq ctrl-char -> nothing" "" "$got"
# A Unicode arrow / multibyte display passes the guard and is painted verbatim.
check "paint_seq unicode display ok" (printf '%s[s%s[90m%s%s[0m%s[u' $ESC $ESC ' → ls' $ESC $ESC) (_nh_paint_seq ' → ls')

# render_seq: pull field 2 (display) from a real compute record and paint it — drives the pipeline.
set -l grec (_nh_compute_suggestion 'git' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')
check "render_seq ghost (display=' status')" (printf '%s[s%s[90m%s%s[0m%s[u' $ESC $ESC ' status' $ESC $ESC) (_nh_render_seq "$grec")
set -l hrec (_nh_compute_suggestion 'gti' '{"suggestions":[{"text":"git status","replace_start":0,"replace_end":3}]}')
check "render_seq hint (display=' -> git status')" (printf '%s[s%s[90m%s%s[0m%s[u' $ESC $ESC ' -> git status' $ESC $ESC) (_nh_render_seq "$hrec")
check "render_seq empty record -> nothing" "" (_nh_render_seq "")
# A 1-field (no-tab) record paints nothing. The `count >= 2` guard is belt-and-suspenders here — on a
# 1-field record $fields[2] is out-of-range (empty) and _nh_paint_seq rejects the empty display anyway
# — so this pins the BEHAVIOR (garbage record => no paint, field-1 never mis-painted as the display),
# not the guard line in isolation. Field-2 (not field-1) selection is pinned by the ghost/hint rows
# above, which paint the display rather than the "ghost"/"hint" kind.
check "render_seq 1-field record -> nothing" "" (_nh_render_seq onlykind)
# Minimal VALID record — exactly 2 fields (kind + display, no accept payload) — still paints field 2.
# Brackets the `>= 2` boundary from the passing side and catches an off-by-one in `string split -m 4`.
check "render_seq minimal 2-field record paints display" \
    (printf '%s[s%s[90m%s%s[0m%s[u' $ESC $ESC ' list' $ESC $ESC) (_nh_render_seq (printf 'ghost\t list'))

# input_changed: status 0 == changed (re-query), 1 == unchanged. Cursor is part of the key (EOL-only).
_nh_input_changed git 3 git 3; check "input_changed same -> unchanged" 1 $status
_nh_input_changed git 3 'git ' 4; check "input_changed buffer -> changed" 0 $status
_nh_input_changed git 3 git 2; check "input_changed cursor only -> changed" 0 $status

# ======================================================================================
# H3 async-core state: per-session run dir, cross-process generation, cleanup. HERMETIC — TMPDIR is
# redirected to a sandbox so _nh_state_init's GC of "other sessions" can only ever touch the sandbox,
# never a real run dir on the box. The interactive guard never ran (non-interactive source), so
# _nh_run_dir is unset and the helpers would otherwise no-op — we inject a run dir to drive them.
# ======================================================================================
set -l _h3_saved_tmpdir "$TMPDIR"
set -gx TMPDIR (mktemp -d)

# _nh_bump_gen: the in-process counter and the gen FILE advance together (single monotonic mutator —
# the SOLE cross-process staleness token a worker re-reads to detect it was superseded).
set -g _nh_run_dir (mktemp -d)
set -g _nh_gen 0
_nh_bump_gen
check "bump gen var 1" 1 $_nh_gen
check "bump gen file 1" 1 (cat "$_nh_run_dir/gen")
_nh_bump_gen
check "bump gen var 2" 2 $_nh_gen
check "bump gen file 2" 2 (cat "$_nh_run_dir/gen")
rm -rf "$_nh_run_dir"

# Inertness contract: with no run dir, _nh_bump_gen leaves the counter untouched (this no-op on an
# unset _nh_run_dir is exactly what keeps the live layer dormant under a non-interactive source).
set -g _nh_run_dir ""
set -g _nh_gen 5
_nh_bump_gen
check "bump gen no-op when run dir unset" 5 $_nh_gen

# _nh_state_init: mints a 0700 run dir stamped with this fish PID, with the gen file initialized to 0.
_nh_state_init
check "state_init created a dir" 1 (test -d "$_nh_run_dir"; and echo 1; or echo 0)
check "state_init dir is mode 0700" 700 (stat -c '%a' "$_nh_run_dir")
check "state_init gen file is 0" 0 (cat "$_nh_run_dir/gen")
check "state_init dir carries our pid" 1 (string match -q "*/nighthawk-plugin-$fish_pid-*" -- "$_nh_run_dir"; and echo 1; or echo 0)
set -l _h3_first_dir "$_nh_run_dir"

# Re-init reaps THIS shell's prior dir (same PID) and mints a fresh one — the re-source teardown that
# orphans a prior load's in-flight workers (their `cat gen` then hits ENOENT and they exit).
_nh_state_init
check "state_init reaped the prior same-pid dir" 0 (test -d "$_h3_first_dir"; and echo 1; or echo 0)
check "state_init minted a fresh dir" 1 (test -d "$_nh_run_dir"; and echo 1; or echo 0)

# GC: a foreign dir whose PID is no longer alive is collected; a non-numeric-suffix dir is left alone
# (its PID can't be parsed, so it's skipped rather than wrongly deleted).
set -l _h3_dead "$TMPDIR/nighthawk-plugin-999999-deadbeef"
mkdir -p "$_h3_dead"
set -l _h3_notpid "$TMPDIR/nighthawk-plugin-notapid-xx"
mkdir -p "$_h3_notpid"
_nh_state_init
check "state_init GC removed dead-pid dir" 0 (test -d "$_h3_dead"; and echo 1; or echo 0)
check "state_init left non-pid dir alone" 1 (test -d "$_h3_notpid"; and echo 1; or echo 0)

# _nh_cleanup: removes our run dir; the marker guard refuses a foreign path so a bare `rm -rf "$var"`
# can never escape onto an unrelated directory.
set -l _h3_live "$_nh_run_dir"
_nh_cleanup
check "cleanup removed our run dir" 0 (test -d "$_h3_live"; and echo 1; or echo 0)
set -g _nh_run_dir "$TMPDIR"          # a real dir WITHOUT the nighthawk-plugin- marker
_nh_cleanup
check "cleanup refuses a foreign path (sandbox survives)" 1 (test -d "$TMPDIR"; and echo 1; or echo 0)
set -g _nh_run_dir ""

# Restore TMPDIR + reset state for the config-precedence section below.
rm -rf "$TMPDIR"
if test -n "$_h3_saved_tmpdir"
    set -gx TMPDIR "$_h3_saved_tmpdir"
else
    set -e TMPDIR
end

# ======================================================================================
# H4 accept-splice (PURE) — the revalidate-and-splice kernel behind the commandline-bound _nh_accept.
# Args: <buffer> <cursor_chars> <curgen> <sgen> <bstart> <bend> <text>. Prints "<newcur>\t<newbuf>" on a
# valid accept, NOTHING on any reject. The interactive _nh_accept/_nh_stash_ready that wrap it use
# `commandline` (interactive-only), so the security-critical logic is tested here, directly.
# ======================================================================================
# Whole-buffer replace at EOL: "git ch" -> "git checkout" (bstart/bend 0..6, gen matches). newcur = 12.
check "splice whole-replace" (printf '12\tgit checkout') \
    (_nh_accept_splice 'git ch' 6 5 5 0 6 'git checkout')
# Append at EOL: cursor inside "git " (rstart==blen), ghost text "status" appended. before="git ".
check "splice append-at-eol" (printf '10\tgit status') \
    (_nh_accept_splice 'git ' 4 7 7 4 4 'status')
# Stale generation (sgen != curgen) -> reject (the core cross-process staleness guard).
check "splice stale gen rejected" "" (_nh_accept_splice 'git ch' 6 6 5 0 6 'git checkout')
# Control char in the stashed text (planted-newline auto-submit vector) -> reject, even post-stash.
check "splice ctrl-char text rejected" "" \
    (_nh_accept_splice 'git ch' 6 5 5 0 6 (printf 'git checkout\n' | string collect -N))
# Cursor not at EOL (a stash outliving an unbound cursor move) -> reject.
check "splice off-EOL rejected" "" (_nh_accept_splice 'git ch' 3 5 5 0 6 'git checkout')
# Non-digit byte offset -> reject before any arithmetic.
check "splice non-digit offset rejected" "" (_nh_accept_splice 'git ch' 6 5 5 x 6 'git checkout')
# Inverted range (bend < bstart) -> reject (accept never trusts the worker's [bstart,bend) ordering).
check "splice inverted range rejected" "" (_nh_accept_splice 'git ch' 6 5 5 6 0 'git checkout')
# Byte offset landing mid-codepoint: "café" is 5 bytes / 4 chars; bend=4 splits the é -> reject.
check "splice mid-codepoint rejected" "" (_nh_accept_splice 'café' 4 5 5 0 4 'x')
# Multibyte valid: replace all of "café" (bytes 0..5) with "café list". newcur = 9 code points.
check "splice multibyte ok" (printf '9\tcafé list') \
    (_nh_accept_splice 'café' 4 5 5 0 5 'café list')

# ======================================================================================
# Config precedence (default < file < env) + debounce clamp. Re-sources under different config/env.
# ======================================================================================
# 1. Defaults (empty temp config dir, env unset).
set -e NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_TAB_ACCEPT
rm -f "$XDG_CONFIG_HOME/nighthawk/config.toml"
source "$_nh_plugin"
check "cfg default arrow" "->" "$_nh_hint_arrow"
check "cfg default debounce" 200 "$_nh_debounce_ms"
check "cfg default debug" 0 "$_nh_debug"
check "cfg default tab_accept" 0 "$_nh_tab_accept"

# 2. File overrides default.
mkdir -p "$XDG_CONFIG_HOME/nighthawk"
printf '%s\n' '# comment' '[other]' 'hint_arrow = "XX"' '[plugin]' 'hint_arrow = "=>"' \
    'debounce_ms = 350' 'debug = true' 'tab_accept = true' >"$XDG_CONFIG_HOME/nighthawk/config.toml"
source "$_nh_plugin"
check "cfg file arrow" "=>" "$_nh_hint_arrow"
check "cfg file debounce" 350 "$_nh_debounce_ms"
check "cfg file debug" 1 "$_nh_debug"
check "cfg file tab_accept" 1 "$_nh_tab_accept"

# 3. Env overrides file (tab_accept: file says true, env forces 0).
set -gx NIGHTHAWK_HINT_ARROW ">>"
set -gx NIGHTHAWK_DEBOUNCE_MS 99
set -gx NIGHTHAWK_DEBUG 1
set -gx NIGHTHAWK_TAB_ACCEPT 0
source "$_nh_plugin"
check "cfg env arrow" ">>" "$_nh_hint_arrow"
check "cfg env debounce" 99 "$_nh_debounce_ms"
check "cfg env tab_accept" 0 "$_nh_tab_accept"

# 4. Clamp: non-digit env resets to default; leading-zero normalizes (decimal, no octal).
set -gx NIGHTHAWK_DEBOUNCE_MS foo
source "$_nh_plugin"
check "cfg clamp non-digit -> 200" 200 "$_nh_debounce_ms"
set -gx NIGHTHAWK_DEBOUNCE_MS 0200
source "$_nh_plugin"
check "cfg clamp leading-zero -> 200" 200 "$_nh_debounce_ms"
set -e NIGHTHAWK_HINT_ARROW NIGHTHAWK_DEBOUNCE_MS NIGHTHAWK_DEBUG NIGHTHAWK_TAB_ACCEPT

# 5. Explicitly-empty file value falls back to the default. The hand-rolled TOML reader uses
# `--groups-only`, whose capture for `hint_arrow = ""` is empty -> count 0 -> the default is kept
# (the documented edge at the top of _nh_load_config). Env is unset above, so the file value is
# authoritative — this pins that documented-but-previously-untested fallback.
printf '%s\n' '[plugin]' 'hint_arrow = ""' >"$XDG_CONFIG_HOME/nighthawk/config.toml"
source "$_nh_plugin"
check "cfg empty-string file value -> default arrow" "->" "$_nh_hint_arrow"

# 6. Control-char arrow sanitization — an INJECTION SEAM: the arrow rides the same display field as the
# control-char-guarded daemon text, so an ESC in the config/env arrow must fall back to the default
# before it can reach the renderer (plugin line ~146). env wins over file, so drive it via env with an
# ESC-bearing string and assert the fallback. The guard itself is well-tested; this pins its APPLICATION.
rm -f "$XDG_CONFIG_HOME/nighthawk/config.toml"
set -gx NIGHTHAWK_HINT_ARROW (printf 'a\x1bb' | string collect -N)
source "$_nh_plugin"
check "arrow with ESC -> default" "->" "$_nh_hint_arrow"
set -e NIGHTHAWK_HINT_ARROW

# --- summary ---
rm -rf "$XDG_CONFIG_HOME"
printf 'helpers.test.fish: %d passed, %d failed\n' $_nh_pass $_nh_fail
test $_nh_fail -eq 0
