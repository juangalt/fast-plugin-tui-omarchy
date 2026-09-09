#!/bin/bash

# End-to-end key-binding tests for bin/oma-quick-plugin-tui.
#
# Every case starts the TUI under a pseudo-terminal (tests/ptydrive.py, which
# also answers terminal queries like a real terminal so gum behaves as it does
# in foot), injects key bytes, and asserts on the control-sequence-stripped
# typescript. Runs in dry-run mode against a private cache seeded from
# ~/.cache/oma-quick-plugin-tui (override with OPT_TEST_SEED=<dir holding
# catalog.json + stats.json>), so the real cache and any running TUI are
# never touched. Nothing is downloaded: ctrl-r refreshes from file:// URLs.
#
# Usage: tests/keys.sh [case-name ...]      (default: the whole matrix)
#        KEEP=1 tests/keys.sh               keep the work dir for inspection

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
TUI=$ROOT/bin/oma-quick-plugin-tui
DRIVER=$HERE/ptydrive.py
SEED=${OPT_TEST_SEED:-$HOME/.cache/oma-quick-plugin-tui}
COLS=${COLS_OVERRIDE:-160}
ROWS=${ROWS_OVERRIDE:-45}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/opt-keys.XXXXXX")
export OPT_TEST_ID="opt-keys-$$-$RANDOM"   # every process we start inherits this

pass=0 fail=0
declare -a REPORT=()

# ------------------------------------------------------------------ setup ---

die() { echo "keys.sh: $*" >&2; exit 2; }

# pids of processes started by this test run, found by the env marker — never
# by name, so a TUI the user has open elsewhere is left alone.
test_pids() {
  local f
  for f in /proc/[0-9]*/environ; do
    grep -qzs "^OPT_TEST_ID=$OPT_TEST_ID\$" "$f" 2>/dev/null || continue
    f=${f#/proc/}; f=${f%/environ}
    [[ $f == "$$" ]] || echo "$f"
  done
}

cleanup() {
  local pids
  pids=$(test_pids)
  if [[ -n $pids ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null; sleep 0.3
    # shellcheck disable=SC2086
    kill -KILL $(test_pids) 2>/dev/null
  fi
  if [[ ${KEEP:-0} == 1 ]]; then echo "work dir kept: $WORK"; else rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

[[ -x $TUI ]] || die "not found: $TUI"
[[ -f $SEED/catalog.json && -f $SEED/stats.json ]] ||
  die "need $SEED/catalog.json and stats.json to seed the test cache (run the TUI once, or set OPT_TEST_SEED)"
command -v python3 >/dev/null || die "python3 is required"

mkdir -p "$WORK/seed" "$WORK/cache" "$WORK/run" "$WORK/bin" "$WORK/cases"
cp -- "$SEED/catalog.json" "$SEED/stats.json" "$WORK/seed/"

# xdg-open shim: log instead of opening a browser.
cat >"$WORK/bin/xdg-open" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$OPT_TEST_XDG_LOG"
SHIM
chmod +x "$WORK/bin/xdg-open"
export OPT_TEST_XDG_LOG="$WORK/xdg-open.log"

export XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/run"
export OMA_QUICK_PLUGIN_TUI_DRY_RUN=1
export OMA_QUICK_PLUGIN_TUI_CATALOG_URL="file://$WORK/seed/catalog.json"
export OMA_QUICK_PLUGIN_TUI_STATS_URL="file://$WORK/seed/stats.json"
export PATH="$WORK/bin:$PATH"

# Warm the private cache headlessly (plain curl from file://, no gum).
"$TUI" __refresh-cache </dev/null >/dev/null || die "could not seed the test cache"
TOTAL=$("$TUI" __rows | wc -l)
FIRST_ID=$("$TUI" __rows | head -n1 | cut -f1)     # item #1: bottom row in fzf's layout
LAST_ID=$("$TUI" __rows | tail -n1 | cut -f1)      # last item: top row
FIRST_NAME=$("$TUI" __rows | head -n1 | cut -f3 | cut -c1-20 | sed 's/[][\.*^$+?(){}|]/\\&/g')
LAST_NAME=$("$TUI" __rows | tail -n1 | cut -f3 | cut -c1-20 | sed 's/[][\.*^$+?(){}|]/\\&/g')
(( TOTAL > 1 )) && [[ -n $FIRST_ID && -n $LAST_ID ]] || die "no rows"

# ---------------------------------------------------------------- runner ---

# run_case <name> <steps-on-stdin>: runs the TUI through the driver. Sets
# $DIR, $TS (typescript), $RES (results), $ERR (stderr) and CASE_RC.
run_case() {
  local name="$1"
  DIR="$WORK/cases/$1"
  mkdir -p "$DIR"
  cat >"$DIR/steps"
  TS="$DIR/typescript" RES="$DIR/results" ERR="$DIR/stderr"
  timeout 150 python3 "$DRIVER" --cols "$COLS" --rows "$ROWS" --timeout 120 \
    --log "$TS" --marks "$DIR/marks" --results "$RES" --stderr "$ERR" \
    --screens "$DIR/screens" --steps "$DIR/steps" -- "$TUI"
  CASE_RC=$?
}

# Common checks after a case: every step OK, nothing on stderr, no leftovers
# (the detached header-unhighlight sleeper lives 1.3 s, so poll briefly).
check_common() {
  local bad="" i
  grep -q '^FAIL' "$RES" && bad+=" step-failed"
  [[ -s $ERR ]] && bad+=" stderr"
  for i in 1 2 3 4 5 6; do
    [[ -z $(test_pids) ]] && break
    sleep 0.5
  done
  [[ -n $(test_pids) ]] && bad+=" leftover-processes"
  echo "$bad"
}

# verdict <name> <expectation> [extra-bad]
verdict() {
  local name="$1" what="$2" bad
  bad="$(check_common)${3:+ $3}"
  local evidence
  evidence=$(grep -v '^INFO' "$RES" | sed 's/^OK   /ok: /; s/^FAIL /FAIL: /' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
  if [[ -z ${bad// } ]]; then
    pass=$((pass + 1)); REPORT+=("PASS | $name | $what | $evidence")
  else
    fail=$((fail + 1)); REPORT+=("FAIL | $name | $what | ${bad# } | $evidence")
    [[ -s $ERR ]] && sed 's/^/    stderr: /' "$ERR"
    if [[ -n $(test_pids) ]]; then
      # shellcheck disable=SC2046
      kill -TERM $(test_pids) 2>/dev/null; sleep 0.3
    fi
  fi
}

# Screen regexes (matched against the emulated screen, MULTILINE).
LOADED="^\s+$TOTAL/$TOTAL \(0\)"          # fzf info line once every row is in and no spinner
HEADER='sort: stars ▾'
POPUP='press esc to close this help'
PREVIEW_LABEL='alt-p: toggle preview'
DONE='Press any key to close'
absent() { printf '\\A(?:(?!%s)[\\s\\S])*\\Z' "$1"; }   # regex: text does not occur anywhere

# Steps every case starts with: list fully loaded, header drawn.
MAIN="waitscreen 30 $LOADED
waitscreen 5 $HEADER
screen main
mark main"
# Steps that assert the main screen is back after an action/popup.
BACK="waitscreen 15 $LOADED
waitscreen 5 $HEADER
waitscreen 5 ^plugins>
nowaitscreen 1 $POPUP"

# ----------------------------------------------------------------- cases ---

case_esc() {
  run_case esc <<STEPS
$MAIN
waitscreen 5 \\A─ Oma Quick Plugin TUI - v0\\.1 ─
send \\x1b
exit 5
STEPS
  verdict esc "esc quits (exit 0); title 'Oma Quick Plugin TUI - v0.1' is at the top-left of the screen"
}

case_ctrl_q() {
  run_case ctrl_q <<STEPS
$MAIN
send \\x11
exit 5
STEPS
  verdict ctrl_q "ctrl-q quits (exit 0)"
}

case_ignored() {
  run_case ignored <<STEPS
$MAIN
send \\x03
sleep 0.5
alive
send \\x07
sleep 0.5
alive
send \\x04
sleep 0.5
alive
waitscreen 2 $HEADER
send \\x1b
exit 5
STEPS
  verdict ignored "ctrl-c, ctrl-g ignored; ctrl-d does not quit; esc still quits"
}

case_alt_s() {
  run_case alt_s <<STEPS
$MAIN
send \\x1bs
waitscreen 5 sort: hearts ▾
send \\x1bs
waitscreen 5 sort: views ▾
screen after
send \\x1b
exit 5
STEPS
  verdict alt_s "alt-s cycles sort: stars → hearts → views"
}

case_alt_c() {
  run_case alt_c <<STEPS
$MAIN
send \\x1bc
waitscreen 5 category: (?!all )[A-Za-z]
screen after
send \\x1b
exit 5
STEPS
  verdict alt_c "alt-c cycles category away from 'all'"
}

case_alt_i_v() {
  run_case alt_i_v <<STEPS
$MAIN
send \\x1bi
waitscreen 5 installed-only: on
send \\x1bv
waitscreen 5 verified-only: on
screen after
send \\x1b
exit 5
STEPS
  verdict alt_i_v "alt-i → installed-only: on; alt-v → verified-only: on"
}

case_alt_S() {
  run_case alt_S <<STEPS
$MAIN
send \\x1bS
waitscreen 5 Sort by
screen picker
send \\x1b
$BACK
send \\x1b
exit 5
STEPS
  verdict alt_S "alt-S shows gum 'Sort by' picker; esc returns to main (no stray popup); esc quits"
}

case_alt_C() {
  run_case alt_C <<STEPS
$MAIN
send \\x1bC
waitscreen 5 Filter by category
screen picker
send \\x1b
$BACK
send \\x1b
exit 5
STEPS
  verdict alt_C "alt-C shows gum 'Filter by category' picker; esc returns to main; esc quits"
}

case_alt_p() {
  run_case alt_p <<STEPS
$MAIN
waitscreen 5 $PREVIEW_LABEL
send \\x1bp
waitscreen 5 $(absent "$PREVIEW_LABEL")
waitscreen 2 $HEADER
screen hidden
send \\x1bp
waitscreen 5 $PREVIEW_LABEL
send \\x1b
exit 5
STEPS
  verdict alt_p "alt-p hides the preview (label gone from the screen), alt-p shows it again"
}

case_alt_scroll() {
  run_case alt_scroll <<STEPS
$MAIN
send \\x1bj
sleep 0.3
send \\x1bj
sleep 0.3
send \\x1bk
sleep 0.3
send \\x1bd
sleep 0.3
send \\x1bu
sleep 0.3
alive
waitscreen 2 $HEADER
send \\x1b
exit 5
STEPS
  verdict alt_scroll "alt-j/k/d/u scroll the preview without error; esc quits"
}

case_help() {
  run_case help <<STEPS
$MAIN
send \\x1bh
waitscreen 5 $POPUP
screen popup
send \\x1b
$BACK
send ?
waitscreen 5 $POPUP
send \\x1b
$BACK
send \\x1b
exit 5
STEPS
  verdict help "alt-h and ? open the help popup; esc closes it and returns to main; esc then quits"
}

case_alt_o() {
  run_case alt_o <<STEPS
$MAIN
send \\x1bo
sleep 1
alive
waitscreen 2 $HEADER
send \\x1b
exit 5
STEPS
  local extra=""
  grep -q '^https\?://' "$OPT_TEST_XDG_LOG" 2>/dev/null || extra="xdg-open-not-called"
  verdict alt_o "alt-o hands the repo URL to xdg-open (got: $(head -n1 "$OPT_TEST_XDG_LOG" 2>/dev/null))" "$extra"
}

# action_case <name> <key-bytes> <regex for the message line> <expectation>
action_case() {
  local name="$1" key="$2" msg="$3"
  run_case "$name" <<STEPS
$MAIN
mark action
send $key
wait 10 $msg
wait 10 $DONE
screen done
send x
$BACK
send \\x1b
exit 5
STEPS
  verdict "$name" "$4"
}

case_enter()  { action_case enter  '\r'   '\[dry-run\] omarchy-plugin-add|already installed|not installable|built into Omarchy' "enter: dry-run install line, Done prompt, a key returns to main, esc quits"; }
case_ctrl_t() { action_case ctrl_t '\x14' 'not installed — press enter|\[dry-run\] omarchy-plugin-(en|dis)able' "ctrl-t: enable/disable message, Done prompt, back to main"; }
case_ctrl_x() { action_case ctrl_x '\x18' 'not installed|\[dry-run\] omarchy-plugin-remove|built into Omarchy' "ctrl-x: remove message, Done prompt, back to main"; }
case_ctrl_o() { action_case ctrl_o '\x0f' 'not installed|\[dry-run\] omarchy-plugin-update|not a git-managed' "ctrl-o: update message, Done prompt, back to main"; }

case_ctrl_r() {
  # Age the cache so the refresh is visible in the header (2h ago → 0s ago).
  touch -d '-2 hours' "$WORK/cache/oma-quick-plugin-tui/catalog.json" "$WORK/cache/oma-quick-plugin-tui/stats.json"
  run_case ctrl_r <<STEPS
waitscreen 30 $LOADED
waitscreen 5 catalog: 2h ago
mark main
send \\x12
waitscreen 20 catalog: [0-9]s ago
$BACK
nowaitscreen 2 $POPUP
screen after
alive
send \\x1b
exit 5
STEPS
  # Evidence that gum spin ran and queried the terminal (the driver answered,
  # so the replies were queued on the tty exactly as in a real terminal).
  local off q extra=""
  off=$(awk '$1=="main"{print $2}' "$DIR/marks")
  q=$(tail -c +$((off + 1)) "$TS" | grep -ao $'\e\[?2026\$p' | wc -l)
  (( q >= 1 )) || extra="gum-did-not-query-terminal"
  verdict ctrl_r "ctrl-r re-downloads via gum spin ($q DECRQM queries answered), main screen back with NO help popup, esc quits" "$extra"
}

case_home_end() {
  run_case home_end <<STEPS
$MAIN
send \\x1b[H
pointer 5 ^1:.*$LAST_NAME
screen home
mark action1
send \\x14
wait 10 $LAST_ID: not installed|omarchy-plugin-(en|dis)able $LAST_ID
wait 10 $DONE
send x
$BACK
send \\x1b[F
pointer 5 ^[0-9]+:.*$FIRST_NAME
screen end
mark action2
send \\x14
wait 10 $FIRST_ID: not installed|omarchy-plugin-(en|dis)able $FIRST_ID
wait 10 $DONE
send x
$BACK
send \\x1b
exit 5
STEPS
  verdict home_end "home → pointer on the top row (last item, $LAST_ID); end → bottom row (item #1, $FIRST_ID); ctrl-t on each confirms the id"
}

ALL=(esc ctrl_q ignored alt_s alt_c alt_i_v alt_S alt_C alt_p alt_scroll help alt_o enter ctrl_t ctrl_x ctrl_o ctrl_r home_end)

# ------------------------------------------------------------------- main ---

cases=("$@"); (( ${#cases[@]} )) || cases=("${ALL[@]}")
for c in "${cases[@]}"; do
  printf '%-12s ' "$c"
  "case_$c"
  echo "${REPORT[-1]%% |*}"
done

echo
printf '%s\n' "result | case | expectation | evidence" "---|---|---|---" "${REPORT[@]}"
echo
echo "passed: $pass  failed: $fail  (work dir: $WORK)"
(( fail == 0 ))
