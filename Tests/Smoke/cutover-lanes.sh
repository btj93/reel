#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=Tests/Smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=Tests/Smoke/pointer-lib.sh
source "$SCRIPT_DIR/pointer-lib.sh"
DRY="${SMOKE_DRY_RUN:-0}"
SMOKE_TAG="$$"
BIN_DIR="$REPO_ROOT/.build/debug"
BIN_MSG="$BIN_DIR/reel-msg"
BIN_HOST="$BIN_DIR/TestWindowHost"
BUNDLE="${REEL_LANE_BUNDLE:-$REPO_ROOT/.build/bundled/Reel.app}"
BIN_REEL="$BUNDLE/Contents/MacOS/Reel"
NS="${R7_LANE_NS:-/tmp/reel-cutover-lanes-$$}"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
OUT="${LANE_OUT:-$NS/evidence}"
TEST_REEL_PID=""

cleanup() {
    quit_reel
    host_quit MAIN
}
trap cleanup EXIT INT TERM

quit_reel() {
    [ -n "$TEST_REEL_PID" ] || return 0
    REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" quit >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$TEST_REEL_PID" 2>/dev/null && fail "sandbox did not quit cleanly" || true
    TEST_REEL_PID=""
}

operator_step() {
    if [ "$DRY" = 1 ]; then dry_echo "$*"; return; fi
    printf '\n%s\nPress Enter only after the stated check passes.\n' "$*"
    read -r
}

shot() {
    if [ "$DRY" = 1 ]; then dry_echo "save $OUT/$1.png"; return; fi
    screencapture -x "$OUT/$1.png"
}

launch_reel() {
    if [ "$DRY" = 1 ]; then dry_echo "launch signed $BUNDLE with sandbox paths and host PID allowlist"; return; fi
    REEL_SOCKET_PATH="$SOCK" REEL_CONFIG_DIR="$CFG" REEL_STATE_DIR="$STATE" REEL_MANAGE_ONLY_PIDS="${HOST_PID[MAIN]}" REEL_LOG_PATH="$REEL_LOG" \
        "$BIN_REEL" > "$REEL_LOG" 2>&1 &
    TEST_REEL_PID=$!
}

fresh() {
    quit_reel
    host_quit MAIN
    host_start MAIN
    host_create MAIN 4 >/dev/null
    write_test_config "$CFG" 16
    gesture_config "$CFG" "$BIN_REEL"
    launch_reel
    if [ "$DRY" != 1 ]; then poll_until 10 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null" || fail "no signed runtime"; fi
    waitForSettle 10
}

switch_space() {
    if [ "$DRY" = 1 ]; then dry_echo "Ctrl key $1 then Space settle"; return; fi
    osascript -e "tell application \"System Events\" to key code $1 using control down"
    sleep 1.5
}

lane1() {
    section "lane 1: trunk versus head smoke"
    if [ "$DRY" = 1 ]; then
        dry_echo "REEL_E2E_CONFIRM=1 make -C TRUNK_ROOT smoke; then head make smoke; compare every section and save smoke-summary.png"
        return
    fi
    [ -d "${TRUNK_ROOT:-}/Tests/Smoke" ] || fail "TRUNK_ROOT must be a distinct trunk checkout"
    [ "$(cd "$TRUNK_ROOT" && pwd)" != "$REPO_ROOT" ] || fail "trunk and head must be distinct"
    REEL_E2E_CONFIRM=1 make -C "$TRUNK_ROOT" smoke 2>&1 | tee "$OUT/trunk-smoke.log"
    REEL_E2E_CONFIRM=1 make -C "$REPO_ROOT" smoke 2>&1 | tee "$OUT/head-smoke.log"
    operator_step "Verify head passes every section trunk passes. Capture the two summaries."
    shot smoke-summary
}

first_run() {
    local slug=$1 expected=$2
    section "$slug: first grant on macOS $expected"
    quit_reel
    host_quit MAIN
    host_start MAIN
    host_create MAIN 4 >/dev/null
    rm -rf "$CFG" "$STATE"
    mkdir -p "$CFG" "$STATE"
    if [ "$DRY" != 1 ]; then
        [ "$(sw_vers -productVersion | cut -d. -f1)" = "$expected" ] || fail "requires macOS $expected"
    fi
    operator_step "Use a fresh isolated lane account with no grant for this signed bundle. Do not reset daily-machine TCC."
    launch_reel
    operator_step "Grant Accessibility to $BUNDLE and press Enter immediately."
    if [ "$DRY" != 1 ]; then poll_until 5 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null" || fail "no runtime within five seconds"; fi
    waitForSettle 5
    operator_step "Confirm all host windows tiled within five seconds of the grant, and a new schema config was created."
    shot "$slug"
}
lane2() { first_run first-run 27; }
lane3() { first_run first-run-15 15; }

lane4() {
    section "lane 4: login item across reboot"
    operator_step "On the isolated lane account, launch $BUNDLE normally, enable Start at Login and approve it in System Settings. Reboot. After login, rerun only lane 4 with R7_LOGIN_AFTER_REBOOT=1."
    if [ "${R7_LOGIN_AFTER_REBOOT:-0}" = 1 ]; then
        operator_step "Confirm the same signed Reel bundle is running and tiling after login, and Start at Login is checked."
        shot login
    elif [ "$DRY" != 1 ]; then fail "reboot checkpoint prepared; rerun lane 4 after login"; fi
}

lane5() {
    section "lane 5: signed bundle Space round trip"
    fresh
    local before; before=$(col_window_ids)
    for _ in $(seq 1 20); do
        switch_space 124
        waitForSettle 10
        switch_space 123
        waitForSettle 10
        if [ "$DRY" != 1 ]; then [ "$(col_window_ids)" = "$before" ] || fail "Space return changed order"; fi
    done
    shot space-roundtrip
}

lane6() {
    section "lane 6: unplug a display"
    fresh
    operator_step "On a two-display lane host, place host columns on the secondary. Unplug it. Confirm every window migrates on-screen, then reconnect and confirm none is lost."
    waitForSettle 10
    reel_msg get-layouts > "$OUT/unplug-layouts.json"
    shot unplug
}

lane7() {
    section "lane 7: signed bundle reorder"
    if [ "$DRY" = 1 ]; then
        REEL_E2E_CONFIRM=1 SMOKE_DRY_RUN=1 BIN_HEAD="$BIN_REEL" LANE_OUT="$OUT" bash "$SCRIPT_DIR/pointer-lanes.sh" 7
    else
        REEL_E2E_CONFIRM=1 BIN_HEAD="$BIN_REEL" LANE_OUT="$OUT" bash "$SCRIPT_DIR/pointer-lanes.sh" 7
    fi
    operator_step "Verify the dragged column drops at the highlighted slot. Keep reorder.png."
}

rss_kb() {
    if [ "$DRY" = 1 ]; then echo 40000; else ps -o rss= -p "$TEST_REEL_PID" | tr -d ' '; fi
}
lane8() {
    section "lane 8: 30 minute focus/move/width/Space soak"
    fresh
    local start=$SECONDS base now growth i=0
    base=$(rss_kb)
    printf 'seconds\trss_kb\n0\t%s\n' "$base" > "$OUT/soak-rss.tsv"
    while [ "$DRY" = 1 ] || [ $((SECONDS-start)) -lt 1800 ]; do
        for command in focus-right focus-left move-column-right move-column-left cycle-width-preset; do reel_msg "$command" >/dev/null; done
        switch_space 124; waitForSettle 10
        switch_space 123; waitForSettle 10
        now=$(rss_kb)
        printf '%s\t%s\n' "$((SECONDS-start))" "$now" >> "$OUT/soak-rss.tsv"
        growth=$((now-base))
        [ "$growth" -lt 20480 ] || fail "RSS grew by ${growth} KB"
        i=$((i+1))
        [ "$DRY" != 1 ] || break
        sleep 5
    done
    if [ "$DRY" != 1 ]; then ! grep -Ei 'error|failed|invariant' "$REEL_LOG" || fail "soak log has error lines"; fi
    shot soak
}

lane9() {
    section "lane 9: quit mid-animation"
    fresh
    reel_msg focus-left >/dev/null
    waitForSettle 10
    reel_msg focus-right >/dev/null
    reel_msg quit >/dev/null
    if [ "$DRY" != 1 ]; then
        for _ in $(seq 1 100); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
        kill -0 "$TEST_REEL_PID" 2>/dev/null && fail "quit did not finish" || true
        TEST_REEL_PID=""
    fi
    operator_step "Verify every host window is on-screen after quitting. Use the host census, not Reel's cached layout."
    host_report MAIN > "$OUT/quit-host.json"
    shot quit
}

lane10() {
    section "lane 10: old config rejected without overwriting it"
    fresh
    cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"
    cp "$CFG/config.toml" "$OUT/old-config-input.toml"
    if [ "$DRY" = 1 ]; then
        printf '%s\n' 'config error: unknown key animation.scroll_damping_ratio' > "$OUT/old-config-response.txt"
    elif reel_msg reload-config > "$OUT/old-config-response.txt" 2>&1; then fail "old config reload unexpectedly succeeded"; fi
    grep -q 'unknown key animation.scroll_damping_ratio' "$OUT/old-config-response.txt" || fail "first schema error not returned"
    if [ "$DRY" != 1 ]; then
        cmp "$CFG/config.toml" "$OUT/old-config-input.toml" || fail "old config was overwritten"
        quit_reel; launch_reel
        poll_until 10 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null" || fail "old config prevented launch"
    fi
    waitForSettle 10
    operator_step "Confirm menu shows Config error with the first unknown key (animation.scroll_damping_ratio for the fixture). Confirm default Alt-H/Alt-L hotkeys and default layout work after restart."
    shot old-config
}

lane11() {
    section "upgrade lane: same-path trunk grant versus head cdhash"
    operator_step "Set REEL_LANE_BUNDLE to the installed bundle on an isolated lane account. It must currently contain trunk with an existing Accessibility grant. The same install path will receive head."
    quit_reel
    host_quit MAIN
    host_start MAIN
    host_create MAIN 4 >/dev/null
    cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"
    launch_reel
    waitForSettle 10
    operator_step "Confirm trunk tiles without asking for Accessibility."
    quit_reel
    operator_step "Install the signed head bundle over that trunk bundle at the SAME path using the normal upgrade method. Do not remove the grant or reset TCC."
    write_test_config "$CFG" 16
    if [ "$DRY" != 1 ]; then codesign --verify --deep --strict "$BUNDLE"; fi
    launch_reel
    operator_step "Record whether Accessibility prompts on launch, and whether host windows tile within five seconds. If prompted, record it before granting, then record post-grant tiling separately."
    if [ "$DRY" = 1 ]; then
        dry_echo "write prompted/no-prompt and five-second observations to $OUT/upgrade.txt"
    else
        printf 'Describe prompt and first-five-seconds result, plus post-grant timing if relevant: '
        read -r observation
        printf '%s\n' "$observation" > "$OUT/upgrade.txt"
    fi
    shot upgrade
}

main() {
    [ "${REEL_E2E_CONFIRM:-0}" = 1 ] || fail "lane hosts only; set REEL_E2E_CONFIRM=1"
    if [ "$DRY" != 1 ] && [ "${R7_LOGIN_AFTER_REBOOT:-0}" != 1 ]; then
        ! pgrep -x Reel >/dev/null || fail "a Reel is running; use a clean lane host"
        ! pgrep -x ReelNext >/dev/null || fail "a ReelNext is running; use a clean lane host"
    fi
    mkdir -p "$CFG" "$STATE" "$OUT"
    write_fixtures
    local lanes=("$@")
    [ ${#lanes[@]} -gt 0 ] || lanes=(1 2 3 4 5 6 7 8 9 10 11)
    for lane in "${lanes[@]}"; do "lane$lane"; done
    if [ "$DRY" = 1 ]; then section "R7 lane dry run completed (no live verdict)"
    else section "R7 requested lanes completed"; fi
}
main "$@"
