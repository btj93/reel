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
