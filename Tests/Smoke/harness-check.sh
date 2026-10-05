#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/host" <<'HOST'
#!/usr/bin/env bash
while IFS= read -r command; do
    printf '{"ok":true}\n'
    [ "$command" != '{"cmd":"quit"}' ] || exit 0
done
HOST
cat > "$TMP/binary" <<'BINARY'
#!/usr/bin/env bash
printf '%s\n' "${REEL_LOG_PATH:-missing}" > "$PROBE_LOG"
BINARY
cat > "$TMP/msg" <<'MSG'
#!/usr/bin/env bash
exit 0
MSG
chmod +x "$TMP/host" "$TMP/binary" "$TMP/msg"
(
    source "$SCRIPT_DIR/lib.sh"
    DRY=0 SMOKE_TAG=check NS="$TMP/restart" BIN_HOST="$TMP/host"
    mkdir -p "$NS"
    trap 'host_quit MAIN' EXIT
    host_start MAIN
    host_cmd MAIN '{"cmd":"report"}' | grep -q '"ok":true'
    host_quit MAIN
    [ ! -e "$NS/host-MAIN.in" ]
    host_start MAIN
    host_cmd MAIN '{"cmd":"report"}' | grep -q '"ok":true'
    host_quit MAIN
)
printf 'PASS: owned FIFO supports host restart\n'
(
    source "$SCRIPT_DIR/pointer-lanes.sh"
    NS="$TMP/pointer" SOCK="$NS/socket" CFG="$NS/config" STATE="$NS/state" REEL_LOG="$NS/reel.log"
    DRY=0 BIN_MSG="$TMP/msg" HOST_PID[MAIN]=$$ PROBE_LOG="$TMP/log-path"
    export PROBE_LOG
    mkdir -p "$CFG" "$STATE"
    launch_reel "$TMP/binary"
    wait "$TEST_REEL_PID"
    TEST_REEL_PID=""
    unset 'HOST_PID[MAIN]'
    grep -Fx "$REEL_LOG" "$PROBE_LOG"
    trap - EXIT INT TERM
)
printf 'PASS: pointer launch pins the signed bundle log\n'
(
    source "$SCRIPT_DIR/cutover-lanes.sh"
    NS="$TMP/handoff" CFG="$NS/config" STATE="$NS/state" OUT="$NS/out"
    DRY=0 REEL_E2E_CONFIRM=1 reel_active=0 host_active=0 visits=0
    pgrep() { return 1; }
    write_fixtures() { :; }
    quit_reel() { reel_active=0; }
    host_quit() { host_active=0; }
    probe_lane() {
        [ "$reel_active" = 0 ] && [ "$host_active" = 0 ] || return 1
        reel_active=1 host_active=1
        visits=$((visits+1))
    }
    for lane in $(seq 1 11); do eval "lane$lane() { probe_lane; }"; done
    main 5 7
    [ "$visits" = 2 ]
    quit_reel; host_quit MAIN
    main 1 2 3 4 5 6 7 8 9 10 11
    [ "$visits" = 13 ]
    trap - EXIT INT TERM
)
printf 'PASS: every cutover lane releases its parent sandbox before handoff\n'
perf_rule() {  # <script> <trunk sample> <head sample>: runs the script's rule on one sample per side
    (
        source "$SCRIPT_DIR/$1" 2>/dev/null
        trap - EXIT INT TERM
        DRY=0 SAMPLES="$TMP/samples" FRAMES="$TMP/samples"
        : > "$SAMPLES"
        [ -z "$2" ] || printf 'trunk %s\n' "$2" >> "$SAMPLES"
        [ -z "$3" ] || printf 'head %s\n' "$3" >> "$SAMPLES"
        report
    ) 2>/dev/null
}
for rule in "space-perf.sh 1000 1050 1051" "display-perf.sh 1000 1200 1201" "pointer-perf.sh 5 5.5 5.6" "pointer-perf.sh 8 8 8.001"; do
    read -r script trunk inside over <<< "$rule"
    perf_rule "$script" "$trunk" "$inside" || { printf 'FAIL: %s rejected head %s\n' "$script" "$inside"; exit 1; }
    if perf_rule "$script" "$trunk" "$over"; then printf 'FAIL: %s passed head %s\n' "$script" "$over"; exit 1; fi
    if perf_rule "$script" "$trunk" ""; then printf 'FAIL: %s passed with no head samples\n' "$script"; exit 1; fi
done
printf 'PASS: perf rules compare trunk and head samples although both binaries are named Reel\n'
(
    source "$SCRIPT_DIR/lib.sh"
    NS="$TMP/frames" SOCK="$TMP/frames/sock" CFG="$TMP/frames/config" STATE="$TMP/frames/state" BIN_MSG=/usr/bin/false REEL_LOG="$TMP/no-log"
    mkdir -p "$NS"
    write_fixtures
    DRY=0
    reel_msg() { jq '.groups[0].currentColumns[1].isOffScreen = true' "$NS/fixture-layout.json"; }
    host_report() { jq '.windows[1].frameCG.h = 100' "$NS/fixture-report.json"; }
    (assertFramesAgree MAIN 2 visible) >/dev/null
    if (assertFramesAgree MAIN 2) >/dev/null 2>&1; then
        printf 'FAIL: all-column check skipped the off-screen mismatch\n'; exit 1
    fi
    host_report() { jq '.windows[0].frameCG.h = 100' "$NS/fixture-report.json"; }
    (assertFramesAgree MAIN 2 visible) >/dev/null
    reel_msg() { jq '.groups[0].currentColumns[1].isOffScreen = true | .groups[0].currentColumns[0].regionOverlaps[0].interW = 720' "$NS/fixture-layout.json"; }
    if (assertFramesAgree MAIN 2 visible) >/dev/null 2>&1; then
        printf 'FAIL: visible check skipped a visible mismatch\n'; exit 1
    fi
)
printf 'PASS: physical settle checks visible columns; height is checked only when fully visible; default still checks all columns\n'
(
    source "$SCRIPT_DIR/lib.sh"
    DRY=0
    osascript() { printf '%s\n' "$*"; }
    activate_process 12345 | grep -F 'unix id is 12345'
)
printf 'PASS: activation targets the host process, not the previously focused display\n'
(
    source "$SCRIPT_DIR/cutover-perf.sh"
    trap - EXIT INT TERM
    col_count() { echo 3; }
    reel_msg() { printf '%s\n' "$1" >> "$TMP/warm-walk"; }
    waitForSettle() { :; }
    warm_focus_walk
    expected=$(printf 'focus-left\nfocus-left\nfocus-left\nfocus-right\nfocus-right\nfocus-left\nfocus-left')
    [ "$(cat "$TMP/warm-walk")" = "$expected" ] || { echo 'FAIL: warm-up skipped a column'; exit 1; }
)
printf 'PASS: warm-up visits every column and returns to the left before sampling\n'
(
    source "$SCRIPT_DIR/space-perf.sh"
    trap - EXIT INT TERM
    DRY=0 NS="$TMP/preflight" OUT="$TMP/preflight-evidence" REEL_LOG="$TMP/preflight/reel.log"
    SMOKE_KEEP_NS=1
    unset 'HOST_OUT[MAIN]'
    quit_reel() { :; }
    host_quit() { :; }
    cleanup
)
printf 'PASS: evidence cleanup tolerates a preflight failure before host launch\n'
