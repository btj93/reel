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
    source "$SCRIPT_DIR/cutover-perf.sh"
    trap - EXIT INT TERM
    NS="$TMP/startup" SOCK="$TMP/startup/socket" CFG="$TMP/startup/config" STATE="$TMP/startup/state"
    REEL_LOG="$TMP/startup/reel.log" BIN_MSG="$TMP/startup/msg-stub"
    mkdir -p "$CFG" "$STATE"
    write_fixtures
    jq '.groups[0].currentColumns += [.groups[0].currentColumns[] | .windowID += 2 | .index += 2]' \
        "$NS/fixture-layout.json" > "$NS/four-columns.json"
    export HARNESS_STARTUP="$NS"
    cat > "$BIN_MSG" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
    get-status) echo '{}' ;;
    get-layout)
        n=$(cat "$HARNESS_STARTUP/reads" 2>/dev/null || echo 0)
        n=$((n + 1)); echo "$n" > "$HARNESS_STARTUP/reads"
        count=0
        if [ "$n" -ge 16 ]; then count=4
        elif [ "$n" -ge 11 ]; then count=3
        elif [ "$n" -ge 6 ]; then count=1; fi
        echo "$count" > "$HARNESS_STARTUP/count"
        jq --argjson count "$count" '.groups[0].currentColumns |= .[:$count]' "$HARNESS_STARTUP/four-columns.json"
        ;;
    focus-*) echo "$1" >> "$HARNESS_STARTUP/focus" ;;
esac
STUB
    printf '#!/bin/sh\nexit 0\n' > "$NS/runtime-stub"
    chmod +x "$BIN_MSG" "$NS/runtime-stub"
    DRY=0
    stop_reel() { :; }
    host_quit() { :; }
    host_start() { HOST_PID[MAIN]=12345; }
    host_create() { [ "$2" = 4 ]; }
    write_test_config() { :; }
    activate_process() { echo "$1" >> "$NS/activated"; }
    sleep() { :; }
    fresh head "$NS/runtime-stub"
    wait "$TEST_REEL_PID"
    [ "$(cat "$NS/count")" = 4 ] || { echo 'FAIL: fresh returned before all four windows were discovered'; exit 1; }
    [ "$(cat "$NS/activated" 2>/dev/null)" = 12345 ] || { echo 'FAIL: fresh did not activate the host'; exit 1; }
    expected=$(printf 'focus-left\nfocus-left\nfocus-left\nfocus-left\nfocus-right\nfocus-right\nfocus-right\nfocus-left\nfocus-left\nfocus-left')
    [ "$(cat "$NS/focus" 2>/dev/null)" = "$expected" ] || { echo 'FAIL: fresh did not warm every discovered column'; exit 1; }
)
printf 'PASS: fresh waits for delayed discovery, activates the host and warms all four columns\n'
(
    source "$SCRIPT_DIR/cutover-perf.sh"
    trap - EXIT INT TERM
    NS="$TMP/physical" SOCK="$TMP/physical/socket" CFG="$TMP/physical/config" STATE="$TMP/physical/state"
    REEL_LOG="$TMP/physical/reel.log" BIN_MSG=/usr/bin/false
    mkdir -p "$NS"
    write_fixtures
    DRY=0
    reel_msg() { jq '.groups[0].currentColumns[1].isOffScreen = true' "$NS/fixture-layout.json"; }
    host_report() { jq '.windows[1].frameCG.h = 100' "$NS/fixture-report.json"; }
    poll_until() { eval "$2"; }
    physical_settle
    for dimension in x y w; do
        host_report() { jq --arg dimension "$dimension" '.windows[0].frameCG[$dimension] += 10' "$NS/fixture-report.json"; }
        if (assertFramesAgree MAIN 2 visible) >/dev/null 2>&1; then
            echo "FAIL: visible frame check ignored $dimension mismatch"; exit 1
        fi
    done
)
printf 'PASS: physical_settle uses visible mode and checks x, y and width independently\n'
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
(
    source <(sed '/^SCRIPT_DIR=/d; /^main "\$@"$/d' "$SCRIPT_DIR/smoke.sh")
    trap - EXIT INT TERM
    NS="$TMP/smoke-activation" DRY=0 BIN_MSG=/usr/bin/false
    mkdir -p "$NS"
    HOST_PID[MAIN]=12345
    ensure_clean() { :; }
    waitForSettle() { :; }
    assertFramesAgree() { :; }
    host_create() { [ "$2" = 2 ]; }
    activate_process() { printf '%s\n' "$1" > "$NS/activated"; }
    poll_col_count() { [ "$(cat "$NS/activated" 2>/dev/null)" = 12345 ]; }
    sec_canary
)
printf 'PASS: smoke activates its host before inspecting the active display canary\n'
(
    source "$SCRIPT_DIR/pointer-lanes.sh"
    trap - EXIT INT TERM
    NS="$TMP/failed-pointer" OUT="$TMP/pointer-evidence" REEL_LOG="$TMP/failed-pointer/reel.log"
    mkdir -p "$NS"
    printf 'space notification evidence\n' > "$REEL_LOG"
    SMOKE_KEEP_NS=0
    quit_reel() { :; }
    host_quit() { :; }
    cleanup 1
    [ -d "$NS" ] || { echo 'FAIL: failed pointer lane deleted its namespace'; exit 1; }
    cmp "$REEL_LOG" "$OUT/reel.log" || { echo 'FAIL: failed pointer lane did not export the runtime log'; exit 1; }
)
printf 'PASS: failed pointer lanes keep their namespace and export the runtime log\n'
pointer_switch_probe() {
    (
        local mode=$1
        source "$SCRIPT_DIR/pointer-lanes.sh"
        trap - EXIT INT TERM
        NS="$TMP/switch-$mode" DRY=0
        mkdir -p "$NS"
        echo 4 > "$NS/space"
        echo 0 > "$NS/keys"
        echo 0 > "$NS/reads"
        sleep() { :; }
        osascript() {
            local n; n=$(cat "$NS/keys"); n=$((n+1)); echo "$n" > "$NS/keys"
            if [ "$mode" = immediate ] || { [ "$mode" = retry ] && [ "$n" = 2 ]; }; then echo 5 > "$NS/space"; fi
        }
        reel_msg() {
            if [ "$1" = get-status ]; then echo '{}'; return; fi
            [ "$mode" != unavailable ] || return 1
            local n; n=$(cat "$NS/reads"); echo "$((n+1))" > "$NS/reads"
            printf '{"activeDisplayID":1,"groups":[{"isActive":true,"space":"sid:%s"}]}\n' "$(cat "$NS/space")"
        }
        poll_until() { for _ in 1 2 3; do if eval "$2"; then return 0; fi; done; return 1; }
        fail() { echo "FAIL: $*" >&2; exit 1; }
        switch_space 124
        [ "$(cat "$NS/space")" = 5 ] || { echo 'FAIL: returned without a registered Space change'; exit 1; }
        [ "$(cat "$NS/reads")" -ge 2 ] || { echo 'FAIL: switch did not verify head identity'; exit 1; }
        if [ "$mode" = immediate ]; then [ "$(cat "$NS/keys")" = 1 ]; else [ "$(cat "$NS/keys")" = 2 ]; fi
    )
}
pointer_switch_probe immediate
pointer_switch_probe retry
if pointer_switch_probe ignored > "$TMP/ignored-switch.log" 2>&1; then
    echo 'FAIL: ignored Space switches passed'; exit 1
fi
[ "$(cat "$TMP/switch-ignored/keys")" = 2 ]
grep -q 'Space switch not registered' "$TMP/ignored-switch.log"
if pointer_switch_probe unavailable > "$TMP/unavailable-head.log" 2>&1; then
    echo 'FAIL: unavailable head passed'; exit 1
fi
[ "$(cat "$TMP/switch-unavailable/keys")" = 0 ]
grep -q 'head Space identity unavailable' "$TMP/unavailable-head.log"
if grep -q 'Space switch not registered' "$TMP/unavailable-head.log"; then echo 'FAIL: head failure was labeled an ignored key'; exit 1; fi
printf 'PASS: pointer Space switching verifies identity, retries once and distinguishes unregistered keys\n'
