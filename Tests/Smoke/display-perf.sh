#!/usr/bin/env bash
#
# Tests/Smoke/display-perf.sh — the R5 perf lane: time from a display reconfiguration to a settled layout on every
# display, trunk `Reel` against head `ReelNext`, in interleaved blocks.
#
# Lane hosts only: it opens real windows and changes a display's resolution through `displayplacer`. It refuses to
# run while any Reel or ReelNext is running, and puts the display back in mode A on exit.
#
#   REEL_E2E_CONFIRM=1 PERF_MODE_A="id:<id> res:1920x1080 ..." PERF_MODE_B="id:<id> res:1600x900 ..." \
#       bash Tests/Smoke/display-perf.sh
#   PERF_BLOCKS=2 PERF_PER_BLOCK=5      two blocks of five toggles per binary, alternating (ten each)
#   PERF_BINS="a b"                     binaries to compare, trunk first (default: .build/debug/Reel .build/debug/Reel)
#   SMOKE_DRY_RUN=1                     walk the steps against fixtures, launch nothing
#
# PERF_MODE_A and PERF_MODE_B are `displayplacer` arguments for one display (`displayplacer list` prints them). Each
# sample runs from the `displayplacer` call until `get-layout` reports the new display regions and `waitForSettle`
# returns. Pass when head p95 is at most trunk p95 times 1.2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=Tests/Smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
# waitForSettle reads every group, so a sample ends only once every display has settled.
AG='.groups[]'

DRY="${SMOKE_DRY_RUN:-0}"
SMOKE_TAG="$$"
BIN_DIR="$REPO_ROOT/.build/debug"
BIN_MSG="$BIN_DIR/reel-msg"
BIN_HOST="$BIN_DIR/TestWindowHost"
read -r -a BINS <<< "${PERF_BINS:-${BIN_TRUNK:-/tmp/reel-trunk/.build/debug/Reel} $BIN_DIR/Reel}"
BLOCKS="${PERF_BLOCKS:-2}"
PER_BLOCK="${PERF_PER_BLOCK:-5}"
MODE_A="${PERF_MODE_A:-id:DRY-RUN res:1920x1080}"
MODE_B="${PERF_MODE_B:-id:DRY-RUN res:1600x900}"

NS="/tmp/reel-display-perf-$$"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
SAMPLES="$NS/samples"
TEST_REEL_PID=""
BIN_REEL="${BINS[0]}"
# Global, so the toggles alternate across blocks too and the display always starts a block in a known mode.
MODE=B

cleanup() {
    quit_reel
    host_quit MAIN
    place "$MODE_A"
    if [ "${SMOKE_KEEP_NS:-0}" = 1 ]; then warn "kept $NS"; else rm -rf "$NS"; fi
}
trap cleanup EXIT INT TERM

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# Every group's display regions, the part of the layout a reconfiguration changes.
regions() { reel_msg get-layout | jq -c '[.groups[].regions]'; }

place() {  # <displayplacer arguments>
    if [ "$DRY" = 1 ]; then dry_echo "displayplacer \"$1\""; return 0; fi
    displayplacer "$1" >/dev/null
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
    local bin=$1 count=$2 before t0 t1 mode
    launch_reel "$bin"
    waitForSettle 10
    for _ in $(seq 1 "$count"); do
        before="$(regions)"
        mode="$MODE_A"
        [ "$MODE" = B ] && mode="$MODE_B"
        t0=$(now_ms)
        place "$mode"
        if [ "$DRY" != 1 ]; then
            poll_until 10 "[ \"\$(regions)\" != '$before' ]" || fail "$(basename "$bin") never saw the new display size"
        fi
        waitForSettle 10
        t1=$(now_ms)
        printf '%s %d\n' "$(side "$bin")" $((t1 - t0)) >> "$SAMPLES"
        if [ "$MODE" = B ]; then MODE=A; else MODE=B; fi
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
    if [ "$DRY" != 1 ]; then
        command -v displayplacer >/dev/null || fail "displayplacer is not installed"
        [ -n "${PERF_MODE_A:-}" ] && [ -n "${PERF_MODE_B:-}" ] || fail "set PERF_MODE_A and PERF_MODE_B"
        if pgrep -x Reel >/dev/null || pgrep -x ReelNext >/dev/null; then fail "stop the running Reel or ReelNext first"; fi
    fi
    mkdir -p "$NS" "$CFG" "$STATE"
    : > "$SAMPLES"
    write_fixtures
    place "$MODE_A"
    host_start MAIN
    host_create MAIN 4 >/dev/null
    for _ in $(seq 1 "$BLOCKS"); do
        for bin in "${BINS[@]}"; do measure "$bin" "$PER_BLOCK"; done
    done
    section "display reconfiguration to settled layout (ms)"
    local trunk head
    trunk="$(basename "${BINS[0]}")"
    head="$(basename "${BINS[${#BINS[@]}-1]}")"
    for bin in "${BINS[@]}"; do
        local name; name="$(side "$bin")"
        info "$name: n=$(grep -c "^$name " "$SAMPLES") p50=$(percentile "$name" 50) p95=$(percentile "$name" 95)"
    done
    if [ "$DRY" = 1 ]; then dry_note "rule: $head p95 <= $trunk p95 * 1.2"; return 0; fi
    local limit; limit=$(( $(percentile "$trunk" 95) * 12 / 10 ))
    [ "$(percentile "$head" 95)" -le "$limit" ] || fail "$head p95 above $trunk p95 * 1.2 ($limit)"
    ok "$head p95 within $trunk p95 * 1.2"
}

main "$@"
