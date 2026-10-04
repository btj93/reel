#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=Tests/Smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
DRY="${SMOKE_DRY_RUN:-0}"
SMOKE_TAG="$$"
BIN_DIR="$REPO_ROOT/.build/debug"
BIN_MSG="$BIN_DIR/reel-msg"
BIN_HOST="$BIN_DIR/TestWindowHost"
TRUNK="${BIN_TRUNK:-/tmp/reel-trunk/.build/debug/Reel}"
HEAD="${BIN_HEAD:-$REPO_ROOT/.build/bundled/Reel.app/Contents/MacOS/Reel}"
BIN_REEL="$HEAD"
NS="${R7_PERF_NS:-/tmp/reel-cutover-perf-$$}"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
OUT="${LANE_OUT:-$NS/evidence}"
SAMPLES="$OUT/latency.tsv"
TEST_REEL_PID=""

cleanup() {
    stop_reel
    host_quit MAIN
}
trap cleanup EXIT INT TERM

stop_reel() {
    [ -n "$TEST_REEL_PID" ] || return 0
    REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" quit >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$TEST_REEL_PID" 2>/dev/null && fail "sandbox did not quit" || true
    TEST_REEL_PID=""
}

fresh() {
    local side=$1 bin=$2
    stop_reel
    host_quit MAIN
    host_start MAIN
    host_create MAIN 4 >/dev/null
    write_test_config "$CFG" 16
    if [ "$side" = trunk ]; then cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"; fi
    if [ "$DRY" = 1 ]; then dry_echo "launch $side $bin, host PID allowlist, isolated config/state/socket"; return; fi
    REEL_SOCKET_PATH="$SOCK" REEL_CONFIG_DIR="$CFG" REEL_STATE_DIR="$STATE" REEL_MANAGE_ONLY_PIDS="${HOST_PID[MAIN]}" REEL_LOG_PATH="$REEL_LOG" \
        "$bin" > "$REEL_LOG" 2>&1 &
    TEST_REEL_PID=$!
    poll_until 10 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null" || fail "runtime did not start"
    waitForSettle 10
}

physical_settle() {
    if [ "$DRY" = 1 ]; then assertFramesAgree MAIN 2; return; fi
    poll_until 10 "(assertFramesAgree MAIN 2) > '$NS/physical-last.log' 2>&1" || fail "$(cat "$NS/physical-last.log")"
}

now_ms() { perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.3f\n", clock_gettime(CLOCK_MONOTONIC)*1000'; }

space_settle() {
    local key=$1 expected=$2
    local before; before=$(reel_msg get-layout | jq -c "$AG | (.space // .currentSpaceFingerprint)")
    if [ "$DRY" = 1 ]; then
        reel_msg get-layout | jq -e '.groups | map(select(.isActive)) | .[0].currentColumns | length >= 0' >/dev/null
        dry_echo "Ctrl key $key, wait for $expected columns, then settle"
        return
    fi
    osascript -e "tell application \"System Events\" to key code $key using control down"
    poll_until 10 "[ \"\$(REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-layout | jq -c '$AG | (.space // .currentSpaceFingerprint)')\" != '$before' ] && [ \"\$(REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-layout | jq -c '$AG | (.space // .currentSpaceFingerprint)')\" != null ]" || fail "Space identity did not change"
    poll_until 10 "[ \$(REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-layout | jq -r '.groups | map(select(.isActive)) | .[0].currentColumns | length') -eq '$expected' ]" || fail "Space never changed to expected census"
    waitForSettle 10
}

sample() {
    local side=$1 bin=$2 start stop
    fresh "$side" "$bin"
    reel_msg focus-left >/dev/null
    waitForSettle 10
    physical_settle
    start=$(now_ms)
    reel_msg focus-right >/dev/null
    waitForSettle 10
    physical_settle
    stop=$(now_ms)
    if [ "$DRY" = 1 ]; then printf '%s\tfocus\t100\n' "$side" >> "$SAMPLES"
    else awk -v s="$side" -v a="$start" -v b="$stop" 'BEGIN { printf "%s\tfocus\t%.3f\n", s, b-a }' >> "$SAMPLES"; fi
    start=$(now_ms)
    space_settle 124 0
    stop=$(now_ms)
    if [ "$DRY" = 1 ]; then printf '%s\tspace\t200\n' "$side" >> "$SAMPLES"
    else awk -v s="$side" -v a="$start" -v b="$stop" 'BEGIN { printf "%s\tspace\t%.3f\n", s, b-a }' >> "$SAMPLES"; fi
    space_settle 123 4
    stop_reel
}

cpu_seconds() {
    ps -o cputime= -p "$TEST_REEL_PID" | awk '{ n=split($1,p,":"); total=p[n]+p[n-1]*60; if(n==3) total+=p[1]*3600; printf "%.3f\n", total }'
}

idle() {
    local side=$1 bin=$2 before after
    fresh "$side" "$bin"
    if [ "$DRY" = 1 ]; then
        dry_echo "ps -o cputime before and after five idle minutes for $side"
        printf '%s\t0.500\n' "$side" >> "$OUT/idle.tsv"
    else
        waitForSettle 10
        sleep 2
        before=$(cpu_seconds)
        sleep 300
        after=$(cpu_seconds)
        awk -v s="$side" -v a="$before" -v b="$after" 'BEGIN { printf "%s\t%.3f\n", s, b-a }' >> "$OUT/idle.tsv"
    fi
    stop_reel
}

p95() {
    awk -v side="$1" -v metric="$2" '$1==side && $2==metric {print $3}' "$SAMPLES" | sort -n \
        | awk '{v[NR]=$1} END {if(NR==0) exit 1; i=int(NR*.95); if(i<NR*.95)i++; print v[i]}'
}

main() {
    [ "${REEL_E2E_CONFIRM:-0}" = 1 ] || fail "lane hosts only; set REEL_E2E_CONFIRM=1"
    if [ "$DRY" != 1 ]; then
        ! pgrep -x Reel >/dev/null || fail "a Reel is running; use a clean lane host"
        ! pgrep -x ReelNext >/dev/null || fail "a ReelNext is running; use a clean lane host"
        [ -x "$TRUNK" ] && [ -x "$HEAD" ] || fail "build distinct trunk and head binaries first"
        [ "$TRUNK" != "$HEAD" ] || fail "trunk and head cannot be the same binary"
    fi
    mkdir -p "$CFG" "$STATE" "$OUT"
    write_fixtures
    : > "$SAMPLES"; : > "$OUT/idle.tsv"
    for _ in $(seq 1 20); do sample trunk "$TRUNK"; sample head "$HEAD"; done
    idle trunk "$TRUNK"; idle head "$HEAD"
    for metric in focus space; do
        local trunk head
        trunk=$(p95 trunk "$metric"); head=$(p95 head "$metric")
        info "$metric latency p95 trunk=$trunk ms head=$head ms"
        awk -v t="$trunk" -v h="$head" 'BEGIN {exit !(h<=t*1.1)}' || fail "$metric p95 exceeds trunk * 1.1"
    done
    awk '$1=="head" && $2>1 {exit 1}' "$OUT/idle.tsv" || fail "head idle CPU exceeds 1 second in five minutes"
    if [ "$DRY" = 1 ]; then section "R7 perf dry parser check passed (fixture samples only)"
    else section "R7 perf passed; samples in $OUT"; fi
}
main "$@"
