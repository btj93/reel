#!/usr/bin/env bash
#
# Tests/Smoke/space-perf.sh — the R4 perf lane: time from a Space switch key to a settled strip on the destination
# Space, trunk `Reel` against head `ReelNext`, in interleaved blocks.
#
# Lane hosts only: it opens real windows and posts Ctrl-Left/Right through System Events, which must be bound to
# "Move left/right a space", with at least two Spaces. It refuses to run while any Reel or ReelNext is running.
#
#   REEL_E2E_CONFIRM=1 bash Tests/Smoke/space-perf.sh
#   PERF_BLOCKS=4 PERF_PER_BLOCK=5      four blocks of five switches per binary, alternating (twenty each)
#   PERF_BINS="a b"                     binaries to compare, trunk first (default: .build/debug/Reel .build/debug/Reel)
#   SMOKE_DRY_RUN=1                     walk the steps against fixtures, launch nothing
#
# Each sample runs from the `osascript` call until the active group reports another Space and `waitForSettle`
# returns. Pass when head p95 is at most trunk p95 + 50 ms.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=Tests/Smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY="${SMOKE_DRY_RUN:-0}"
SMOKE_TAG="$$"
BIN_DIR="$REPO_ROOT/.build/debug"
BIN_MSG="$BIN_DIR/reel-msg"
BIN_HOST="$BIN_DIR/TestWindowHost"
read -r -a BINS <<< "${PERF_BINS:-${BIN_TRUNK:-/tmp/reel-trunk/.build/debug/Reel} $BIN_DIR/Reel}"
BLOCKS="${PERF_BLOCKS:-4}"
PER_BLOCK="${PERF_PER_BLOCK:-5}"

NS="/tmp/reel-space-perf-$$"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
SAMPLES="$NS/samples"
TEST_REEL_PID=""
BIN_REEL="${BINS[0]}"
# Global, so the switches alternate across blocks too: a block never starts by switching past the last Space.
DIRECTION=right

cleanup() {
    quit_reel
    host_quit MAIN
    if [ "${SMOKE_KEEP_NS:-0}" = 1 ]; then warn "kept $NS"; else rm -rf "$NS"; fi
}
trap cleanup EXIT INT TERM

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# The active group's Space: `space` from ReelNext, the fingerprint from trunk.
space_id() { reel_msg get-layout | jq -c "$AG | (.space // .currentSpaceFingerprint)"; }

switch_space() {  # left|right
    local code=124
    [ "$1" = left ] && code=123
    if [ "$DRY" = 1 ]; then dry_echo "osascript: key code $code using control down"; return 0; fi
    osascript -e "tell application \"System Events\" to key code $code using control down" >/dev/null
}

# No Reel runs during setup to report the new Space, so wait out the switch animation before opening windows.
setup_switch() {  # left|right
    switch_space "$1"
    if [ "$DRY" = 1 ]; then dry_echo "sleep 1 for the switch to settle"; else sleep 1; fi
}

launch_reel() {  # <binary>
    BIN_REEL=$1
    write_test_config "$CFG" 16
    if [ "$1" = "${BINS[0]}" ]; then cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"; fi
    if [ "$DRY" = 1 ]; then dry_echo "launch $(basename "$1") sandboxed in $NS"; return 0; fi
    REEL_SOCKET_PATH="$SOCK" REEL_CONFIG_DIR="$CFG" REEL_STATE_DIR="$STATE" REEL_MANAGE_ONLY_PIDS="${HOST_PID[MAIN]}" \
        "$1" >> "$REEL_LOG" 2>&1 &
    TEST_REEL_PID=$!
    poll_until 10 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null 2>&1" || fail "$(basename "$1") never answered"
}

quit_reel() {
    [ -n "$TEST_REEL_PID" ] || return 0
    REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" quit >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
    kill -9 "$TEST_REEL_PID" 2>/dev/null || true
    TEST_REEL_PID=""
}

measure() {  # <binary> <count>
    local bin=$1 count=$2 before t0 t1
    launch_reel "$bin"
    waitForSettle 10
    for _ in $(seq 1 "$count"); do
        before="$(space_id)"
        t0=$(now_ms)
        switch_space "$DIRECTION"
        poll_until 5 "[ \"\$(space_id)\" != '$before' ]" || fail "$(basename "$bin") never left Space $before"
        waitForSettle 10
        t1=$(now_ms)
        printf '%s %d\n' "$(side "$bin")" $((t1 - t0)) >> "$SAMPLES"
        if [ "$DIRECTION" = right ]; then DIRECTION=left; else DIRECTION=right; fi
    done
    quit_reel
}

side() { if [ "$1" = "${BINS[0]}" ]; then echo trunk; else echo head; fi; }

percentile() {  # <name> <p>
    grep "^$1 " "$SAMPLES" | awk '{print $2}' | sort -n | awk -v p="$2" '{v[NR]=$1} END {
        if (NR == 0) { print "n/a"; exit }
        i = int(NR * p / 100 + 0.999); if (i < 1) i = 1; print v[i] }'
}

main() {
    [ "${REEL_E2E_CONFIRM:-}" = 1 ] || { warn "Refusing to run: set REEL_E2E_CONFIRM=1 on a lane host."; exit 2; }
    if [ "$DRY" != 1 ] && { pgrep -x Reel >/dev/null || pgrep -x ReelNext >/dev/null; }; then
        fail "stop the running Reel or ReelNext first"
    fi
    mkdir -p "$NS" "$CFG" "$STATE"
    : > "$SAMPLES"
    write_fixtures
    host_start MAIN
    host_create MAIN 3 >/dev/null
    setup_switch right
    host_create MAIN 3 >/dev/null
    setup_switch left
    for _ in $(seq 1 "$BLOCKS"); do
        for bin in "${BINS[@]}"; do measure "$bin" "$PER_BLOCK"; done
    done
    section "space switch to settled strip (ms)"
    local trunk head
    trunk="$(basename "${BINS[0]}")"
    head="$(basename "${BINS[${#BINS[@]}-1]}")"
    for bin in "${BINS[@]}"; do
        local name; name="$(side "$bin")"
        info "$name: n=$(grep -c "^$name " "$SAMPLES") p50=$(percentile "$name" 50) p95=$(percentile "$name" 95)"
    done
    if [ "$DRY" = 1 ]; then dry_note "rule: $head p95 <= $trunk p95 + 50 ms"; return 0; fi
    local limit; limit=$(( $(percentile "$trunk" 95) + 50 ))
    [ "$(percentile "$head" 95)" -le "$limit" ] || fail "$head p95 above $trunk p95 + 50 ms ($limit)"
    ok "$head p95 within $trunk p95 + 50 ms"
}

main "$@"
