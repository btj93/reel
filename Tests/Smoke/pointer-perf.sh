#!/usr/bin/env bash
#
# Tests/Smoke/pointer-perf.sh — the R6 perf lane: main-thread time per frame during a two-second swipe, trunk `Reel`
# against head `Reel`, five interleaved runs per side recorded with the Time Profiler.
#
# Lane hosts only: it opens real windows and posts synthetic input through InputPoster. It refuses to run without
# REEL_E2E_CONFIRM=1 and while any Reel or ReelNext is running.
#
#   REEL_E2E_CONFIRM=1 bash Tests/Smoke/pointer-perf.sh
#   PERF_RUNS=5                          runs per binary, alternating trunk and head
#   PERF_BINS="a b"                      binaries to compare, trunk first (default: .build/debug/Reel .build/debug/Reel)
#   SMOKE_DRY_RUN=1                      walk the steps and summarize a fixture trace; launch and post nothing
#
# Both binaries run the default config's [gesture] settings, and every run starts on column 2 of 6, so the swipe has
# columns on both sides. Each run attaches `xctrace record --template 'Time Profiler'` to the binary, posts the swipe
# from pointer-lib.sh, exports the time-profile table and sums the main thread's sample weights per 16.67 ms frame.
# Pass when head p95 is at most trunk p95 times 1.1 and at most 8 ms.

set -uo pipefail

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
read -r -a BINS <<< "${PERF_BINS:-${BIN_TRUNK:-/tmp/reel-trunk/.build/debug/Reel} $BIN_DIR/Reel}"
RUNS="${PERF_RUNS:-5}"
NS="/tmp/reel-pointer-perf-$$"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
FRAMES="$NS/frames"
TEST_REEL_PID=""
BIN_REEL="${BINS[0]}"

cleanup() {
    quit_reel
    host_quit MAIN
    if [ "${SMOKE_KEEP_NS:-0}" = 1 ]; then warn "kept $NS"; else rm -rf "$NS"; fi
}
trap cleanup EXIT INT TERM

launch_reel() {  # <binary>
    BIN_REEL=$1
    write_test_config "$CFG" 16
    if [ "$1" = "${BINS[0]}" ]; then cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"; fi
    if [ "$1" = "${BINS[0]}" ]; then cp "$SCRIPT_DIR/trunk-config.toml" "$CFG/config.toml"
    else gesture_config "$CFG"; fi
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

# summarize <exported time-profile XML> <name> : one line per frame, "<name> <main-thread ms>", appended to $FRAMES.
# The export dedupes repeated values: an element with `ref` stands for the earlier element with that `id`.
summarize() {
    python3 - "$1" "$2" >> "$FRAMES" <<'PY'
import sys, xml.etree.ElementTree as ET
path, name = sys.argv[1], sys.argv[2]
byid = {}
def resolve(element):
    if element is None:
        return None
    if element.get("ref"):
        return byid.get(element.get("ref"))
    if element.get("id"):
        byid[element.get("id")] = element
    return element
frame = 1e9 / 60
weights = {}
for row in ET.parse(path).getroot().iter("row"):
    for child in row:
        resolve(child)
        for nested in child.iter():
            if nested is not child and nested.get("id"):
                byid[nested.get("id")] = nested
    time, thread, weight = (resolve(row.find(tag)) for tag in ("sample-time", "thread", "weight"))
    if time is None or thread is None or "Main Thread" not in (thread.get("fmt") or ""):
        continue
    bucket = int(int(time.text) // frame)
    weights[bucket] = weights.get(bucket, 0) + (int(weight.text) if weight is not None else 1_000_000)
if weights:
    for bucket in range(min(weights), max(weights) + 1):
        print(f"{name} {weights.get(bucket, 0) / 1e6:.3f}")
PY
}

write_fixture_trace() {  # <path>
    cat > "$1" <<'EOF'
<?xml version="1.0"?>
<trace-query-result><node><schema name="time-profile"/>
<row><sample-time id="1" fmt="00:01.000.000">1000000000</sample-time><thread id="2" fmt="Main Thread  0x1 (Reel, pid: 1)"/><weight id="3" fmt="1.00 ms">1000000</weight></row>
<row><sample-time id="4" fmt="00:01.001.000">1001000000</sample-time><thread ref="2"/><weight ref="3"/></row>
<row><sample-time id="5" fmt="00:01.040.000">1040000000</sample-time><thread ref="2"/><weight ref="3"/></row>
<row><sample-time id="6" fmt="00:01.041.000">1041000000</sample-time><thread id="7" fmt="AXApp 0x2 (Reel, pid: 1)"/><weight ref="3"/></row>
</node></trace-query-result>
EOF
}

run_once() {  # <binary> <run>
    local bin=$1 run=$2 name trace x y
    name=$(side "$bin")
    trace="$NS/$name-$run.trace"
    launch_reel "$bin"
    focus_column 2
    x=$(reel_msg get-layout | jq "$AG | .currentColumns[.activeColumnIndex].frame | (.x + .w / 2 | floor)")
    y=$(reel_msg get-layout | jq "$AG | .currentColumns[.activeColumnIndex].frame | (.y + .h / 2 | floor)")
    if [ "$DRY" = 1 ]; then
        dry_echo "xctrace record --template 'Time Profiler' --attach <pid> --time-limit 3s --output $trace"
        post "perf-swipe" "$(perf_swipe_script "${x:-500}" "${y:-400}" -6)"
        write_fixture_trace "$NS/$name-$run.xml"
    else
        xctrace record --template 'Time Profiler' --attach "$TEST_REEL_PID" --time-limit 3s --output "$trace" >/dev/null 2>&1 &
        local recorder=$!
        sleep 0.5
        post "perf-swipe" "$(perf_swipe_script "$x" "$y" -6)"
        wait "$recorder" || fail "xctrace record failed for $name run $run"
        xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
            > "$NS/$name-$run.xml" || fail "xctrace export failed for $name run $run"
    fi
    summarize "$NS/$name-$run.xml" "$name"
    quit_reel
}

side() { if [ "$1" = "${BINS[0]}" ]; then echo trunk; else echo head; fi; }

percentile() {  # <name> <p> : over every frame of every run
    grep "^$1 " "$FRAMES" | awk '{print $2}' | sort -n | awk -v p="$2" '{v[NR]=$1} END {
        if (NR == 0) { print "n/a"; exit }
        i = int(NR * p / 100 + 0.999); if (i < 1) i = 1; print v[i] }'
}

main() {
    [ "${REEL_E2E_CONFIRM:-}" = 1 ] || { warn "Refusing to run: set REEL_E2E_CONFIRM=1 on a lane host."; exit 2; }
    if [ "$DRY" != 1 ]; then
        command -v xctrace >/dev/null || fail "xctrace is not installed (Xcode)"
        if pgrep -x Reel >/dev/null || pgrep -x ReelNext >/dev/null; then fail "stop the running Reel or ReelNext first"; fi
    fi
    mkdir -p "$NS" "$CFG" "$STATE"
    : > "$FRAMES"
    write_fixtures
    host_start MAIN
    host_create MAIN 6 >/dev/null
    for run in $(seq 1 "$RUNS"); do
        for bin in "${BINS[@]}"; do run_once "$bin" "$run"; done
    done
    report
}

# Samples are tagged by side(), not by binary name: trunk and head are both called Reel since the cutover.
report() {
    section "main-thread ms per frame during a two-second swipe"
    local name
    for name in trunk head; do
        info "$name: frames=$(grep -c "^$name " "$FRAMES") p50=$(percentile "$name" 50) p95=$(percentile "$name" 95)"
    done
    if [ "$DRY" = 1 ]; then dry_note "rule: head p95 <= trunk p95 * 1.1 and <= 8 ms"; return 0; fi
    awk -v h="$(percentile head 95)" -v t="$(percentile trunk 95)" 'BEGIN { exit !(h <= t * 1.1 && h <= 8) }' \
        || fail "head p95 $(percentile head 95) ms is above trunk p95 $(percentile trunk 95) ms * 1.1 or 8 ms"
    ok "head p95 within trunk p95 * 1.1 and 8 ms"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
