#!/usr/bin/env bash
#
# Tests/Smoke/smoke.sh — Layer-3 IPC smoke suite for Reel.
#
# ⚠️  This launches a REAL Reel instance and opens REAL windows on your screen.
#     It STOPS your live Reel for the duration and relaunches it on teardown.
#     It is opt-in only: run via `REEL_E2E_CONFIRM=1 make smoke`.
#
# What makes it safe to run against a daily-driver machine (see §5 of
# docs/superpowers/plans/2026-07-17-programmatic-test-strategy.md):
#   1. REEL_MANAGE_ONLY_PIDS pins the test instance to the TestWindowHost pids —
#      it is structurally unable to rearrange your real windows.
#   2. Hermetic paths: REEL_SOCKET_PATH / REEL_CONFIG_DIR / REEL_STATE_DIR all
#      live under /tmp/reel-smoke-$$ — no collision with the live socket, no
#      pollution of ~/.config/reel or ~/.local/state/reel.
#   3. Empty keybindings + gestures off → the test instance installs no live
#      hotkey/gesture behavior that could eat your input.
#   4. Explicit consent (REEL_E2E_CONFIRM) + never part of `swift run RunTests`.
#   5. Graceful stop of the live Reel + exact-command relaunch on teardown.
#   6. Self-cleaning fixtures ($$-tagged titles); each section clears its windows.
#   7. No synthetic input posted into your session.
#
# Dry-run: SMOKE_DRY_RUN=1 walks every section printing the commands it WOULD
# run and validates every jq filter against embedded fixtures — launches nothing.

set -uo pipefail

# --------------------------- resolve paths ---------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=Tests/Smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY="${SMOKE_DRY_RUN:-0}"
SMOKE_TAG="$$"

BIN_DIR="$REPO_ROOT/.build/debug"
BIN_REEL="$BIN_DIR/Reel"
BIN_MSG="$BIN_DIR/reel-msg"
BIN_HOST="$BIN_DIR/TestWindowHost"

NS="/tmp/reel-smoke-$$"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
PRIMARY_H=""

TEST_REEL_PID=""
LIVE_CMD=""
TEARDOWN_DONE=0

# live_msg: talk to the LIVE (production) instance on its default socket. Scrub
# every REEL_* override out of the environment so this can NEVER hit the test
# socket even if the developer's shell exports one.
live_msg() {
    env -u REEL_SOCKET_PATH -u REEL_CONFIG_DIR -u REEL_STATE_DIR -u REEL_MANAGE_ONLY_PIDS \
        "$BIN_MSG" "$@"
}

# --------------------------- teardown / trap -------------------------------

teardown() {
    [ "$TEARDOWN_DONE" = 1 ] && return 0
    TEARDOWN_DONE=1
    if [ "$DRY" = 1 ]; then
        info "[dry-run] teardown: would quit test instance + relaunch live Reel; cleaning fixture dir $NS"
        [ -n "$NS" ] && [ -d "$NS" ] && rm -rf "$NS"
        return 0
    fi

    info "Teardown — restoring the machine to its pre-smoke state"

    # 1. Best-effort recover, then gracefully quit the TEST instance.
    if [ -n "$TEST_REEL_PID" ]; then
        REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" recover >/dev/null 2>&1 || true
        REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" quit    >/dev/null 2>&1 || true
        # SIGTERM fallback, then reap.
        kill -TERM "$TEST_REEL_PID" 2>/dev/null || true
        for _ in $(seq 1 40); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
        kill -9 "$TEST_REEL_PID" 2>/dev/null || true
    fi

    # 2. Quit the helper hosts and close their held fds.
    host_quit MAIN
    host_quit REAP

    # 3. Remove the namespace.
    [ -n "$NS" ] && [ -d "$NS" ] && rm -rf "$NS"

    # 4. Relaunch the developer's live Reel exactly as it was, then wait for it.
    if [ -n "$LIVE_CMD" ]; then
        info "Relaunching your live Reel: $LIVE_CMD"
        env -u REEL_SOCKET_PATH -u REEL_CONFIG_DIR -u REEL_STATE_DIR -u REEL_MANAGE_ONLY_PIDS \
            nohup sh -c "$LIVE_CMD" >/dev/null 2>&1 &
        disown 2>/dev/null || true
        local up=0
        for _ in $(seq 1 100); do
            if live_msg get-status >/dev/null 2>&1; then up=1; break; fi
            sleep 0.1
        done
        [ "$up" = 1 ] && ok "Live Reel is back and answering its socket" \
                      || warn "Live Reel did not answer within 10s — start it manually"
    else
        warn "No live Reel was running at preflight — nothing to relaunch"
    fi
}
trap teardown EXIT INT TERM

# --------------------------- preflight -------------------------------------

require_confirm() {
    if [ "${REEL_E2E_CONFIRM:-}" != 1 ]; then
        cat >&2 <<EOF
${_c_red}${_c_bld}Refusing to run: REEL_E2E_CONFIRM is not set to 1.${_c_reset}

The smoke suite STOPS your live Reel and opens real windows on your screen.
It is not part of the inner-loop test run (\`swift run RunTests\`).

To run it deliberately:

    ${_c_bld}REEL_E2E_CONFIRM=1 make smoke${_c_reset}

To only lint + build the harness (no launch), use:

    make smoke-check
EOF
        exit 2
    fi
}

require_binaries() {
    local missing=0
    for b in "$BIN_REEL" "$BIN_MSG" "$BIN_HOST"; do
        [ -x "$b" ] || { warn "missing binary: $b"; missing=1; }
    done
    [ "$missing" = 0 ] || fail "build first: swift build   (make smoke does this for you)"
}

# Detect + gracefully stop the developer's live Reel, capturing its exact
# command so teardown can relaunch it verbatim.
stop_live_reel() {
    local pids
    pids="$(pgrep -x Reel || true)"
    if [ -z "$pids" ]; then
        info "No live Reel detected (pgrep -x Reel empty)"
        return 0
    fi
    # First matching pid; capture its full command line before we stop it.
    local pid; pid="$(printf '%s\n' "$pids" | head -n1)"
    LIVE_CMD="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    info "Live Reel running (pid $pid): $LIVE_CMD"
    info "Stopping it gracefully over its real socket…"
    live_msg quit >/dev/null 2>&1 || true
    # Poll until it stops answering; SIGTERM as a fallback.
    local stopped=0
    for _ in $(seq 1 60); do
        if ! live_msg get-status >/dev/null 2>&1; then stopped=1; break; fi
        sleep 0.1
    done
    if [ "$stopped" != 1 ]; then
        warn "Live Reel still answering — sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 60); do
            kill -0 "$pid" 2>/dev/null || { stopped=1; break; }
            sleep 0.1
        done
    fi
    [ "$stopped" = 1 ] && ok "Live Reel stopped" || fail "could not stop the live Reel (pid $pid)"
}

# Launch the sandboxed TEST instance. Reused by the persistence section.
launch_test_reel() {
    : > "$REEL_LOG"
    REEL_SOCKET_PATH="$SOCK" \
    REEL_CONFIG_DIR="$CFG" \
    REEL_STATE_DIR="$STATE" \
    REEL_MANAGE_ONLY_PIDS="$1" \
        "$BIN_REEL" > "$REEL_LOG" 2>&1 &
    TEST_REEL_PID=$!
    # Wait for the socket to answer.
    poll_until 10 "REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-status >/dev/null 2>&1" \
        || fail "test instance never answered its socket ($SOCK) — see $REEL_LOG"
}

# The split-brain guard: before ANY window assertion, prove get-status points
# entirely into our namespace. If any path is the live one, abort immediately.
assert_sandboxed() {
    if [ "$DRY" = 1 ]; then
        reel_msg get-status | jq -e \
            --arg s "$SOCK" --arg c "$CFG" --arg st "$STATE" \
            '.socketPath==$s and .configDir==$c and .stateDir==$st' >/dev/null \
            || fail "fixture get-status is not sandboxed (dry-run shape check)"
        dry_note "split-brain guard: get-status socketPath/configDir/stateDir all in namespace"
        return 0
    fi
    local st; st="$(reel_msg get-status)"
    printf '%s' "$st" | jq -e \
        --arg s "$SOCK" --arg c "$CFG" --arg st "$STATE" \
        '.socketPath==$s and .configDir==$c and .stateDir==$st' >/dev/null \
        || fail "split-brain: test instance is NOT sandboxed — get-status = $st"
    ok "split-brain guard passed (socket/config/state all under $NS)"
}

# --------------------------- section helpers -------------------------------

ensure_clean() {
    host_close_all MAIN
    poll_col_count 4 0 "strip cleared"
}

setup_main_windows() {  # <count>
    ensure_clean
    host_create MAIN "$1" >/dev/null
    poll_col_count 6 "$1" "adopted $1 window(s)"
    waitForSettle
}

# --------------------------- sections --------------------------------------

sec_canary() {
    section "adoption canary — Reel adopts host windows (Accessibility oracle)"
    ensure_clean
    host_create MAIN 2 >/dev/null
    if ! poll_col_count 5 2 "canary: 2 windows adopted within 5s"; then
        cat >&2 <<EOF
${_c_red}${_c_bld}Canary failed: the test Reel did not adopt the host windows.${_c_reset}
This almost always means Accessibility permission is not granted to:
    ${_c_bld}$BIN_REEL${_c_reset}
(The permission is bound to the exact binary path — it resets if you move the
repo. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility.)
EOF
        fail "adoption canary failed (see message above)"
    fi
    waitForSettle
    assertFramesAgree MAIN
    ok "adoption canary passed"
}

sec_focus() {
    section "focus-left / focus-right — active column moves, model matches reality"
    setup_main_windows 2
    local a0; a0="$(active_index)"
    reel_msg focus-left >/dev/null; waitForSettle
    local a1; a1="$(active_index)"
    if [ "$DRY" != 1 ]; then
        [ "$a1" != "$a0" ] || fail "focus-left did not change active column (still $a0)"
        ok "focus-left: active $a0 → $a1"
    else dry_note "would assert active column changed after focus-left"; fi
    assertFramesAgree MAIN
    reel_msg focus-right >/dev/null; waitForSettle
    local a2; a2="$(active_index)"
    if [ "$DRY" != 1 ]; then
        [ "$a2" != "$a1" ] || fail "focus-right did not change active column (still $a1)"
        ok "focus-right: active $a1 → $a2"
    else dry_note "would assert active column changed after focus-right"; fi
    assertFramesAgree MAIN
}

sec_move_column() {
    section "move-column-left / -right — column order changes"
    setup_main_windows 3
    reel_msg focus-right >/dev/null; waitForSettle   # ensure a middle-ish active column to move
    local before; before="$(col_window_ids)"
    reel_msg move-column-left >/dev/null; waitForSettle
    local after; after="$(col_window_ids)"
    if [ "$DRY" != 1 ]; then
        [ "$after" != "$before" ] || fail "move-column-left did not reorder columns ($before)"
        ok "move-column-left reordered: $before → $after"
    else dry_note "would assert windowID order changed: $before → (reordered)"; fi
    reel_msg move-column-right >/dev/null; waitForSettle
    assertFramesAgree MAIN
}

sec_width() {
    section "cycle-width-preset + toggle-full-width — width/presetIndex/isFullWidth"
    setup_main_windows 2
    local p0 w0; p0="$(active_col_field presetIndex)"; w0="$(active_col_field cachedWidth)"
    reel_msg cycle-width-preset >/dev/null; waitForSettle
    local p1 w1; p1="$(active_col_field presetIndex)"; w1="$(active_col_field cachedWidth)"
    if [ "$DRY" != 1 ]; then
        { [ "$p1" != "$p0" ] || [ "$w1" != "$w0" ]; } \
            || fail "cycle-width-preset changed neither presetIndex ($p0) nor width ($w0)"
        ok "cycle-width-preset: preset $p0→$p1, width $w0→$w1"
    else dry_note "would assert presetIndex/cachedWidth changed after cycle-width-preset"; fi

    reel_msg toggle-full-width >/dev/null; waitForSettle
    local fw1; fw1="$(active_col_field isFullWidth)"
    if [ "$DRY" != 1 ]; then
        [ "$fw1" = "true" ] || fail "toggle-full-width did not set isFullWidth=true (got $fw1)"
        ok "toggle-full-width → isFullWidth=true"
    else dry_note "would assert isFullWidth==true after toggle-full-width"; fi

    reel_msg toggle-full-width >/dev/null; waitForSettle
    local fw2; fw2="$(active_col_field isFullWidth)"
    if [ "$DRY" != 1 ]; then
        [ "$fw2" = "false" ] || fail "second toggle-full-width did not clear isFullWidth (got $fw2)"
        ok "toggle-full-width again → isFullWidth=false"
    else dry_note "would assert isFullWidth==false after second toggle-full-width"; fi
    assertFramesAgree MAIN
}

sec_close() {
    section "close-window — column count drops, strip compacts"
    setup_main_windows 3
    reel_msg close-window >/dev/null
    poll_col_count 4 2 "close-window dropped strip 3 → 2 columns"
    waitForSettle
    assertFramesAgree MAIN
}

sec_echo() {
    section "echo suppression in vivo — frameChangeCount bounded then constant"
    setup_main_windows 2
    # After adoption settles a well-behaved manager stops nudging windows: the
    # move/resize notification count must be bounded and then hold steady.
    local c0
    c0="$(host_report MAIN | jq '[.windows[].frameChangeCount] | add')"
    if [ "$DRY" != 1 ]; then
        [ "$c0" -lt 60 ] 2>/dev/null || fail "frameChangeCount unexpectedly high after settle: $c0"
        ok "post-settle frameChangeCount bounded at $c0"
        # Stability window: over 1s the count must NOT grow (no re-nudging).
        local end=$(( $(date +%s) + 1 )) c1
        while [ "$(date +%s)" -lt "$end" ]; do
            c1="$(host_report MAIN | jq '[.windows[].frameChangeCount] | add')"
            [ "$c1" = "$c0" ] || fail "frameChangeCount grew after settle: $c0 → $c1 (echo not suppressed)"
            sleep 0.1
        done
        ok "frameChangeCount held at $c0 over a 1s stability window"
    else
        dry_note "would assert total frameChangeCount bounded (<60) and constant over 1s (fixture: $c0)"
    fi
}

sec_pause_resume() {
    section "pause/resume — paused Reel does NOT correct an external setFrame"
    setup_main_windows 2
    local wid; wid="$(host_window_ids MAIN | awk '{print $1}')"
    [ -n "$wid" ] || wid=1

    reel_msg pause >/dev/null
    if [ "$DRY" != 1 ]; then
        [ "$(reel_msg get-status | jq .isPaused)" = "true" ] || fail "pause did not set isPaused"
        ok "paused (isPaused=true)"
    else dry_note "would assert get-status.isPaused == true"; fi

    # Shove the window to a wild position; a PAUSED manager must leave it there.
    host_cmd MAIN "{\"cmd\":\"setFrame\",\"id\":$wid,\"x\":9000,\"y\":9000,\"w\":420,\"h\":320}" >/dev/null
    assert_host_frame_stable MAIN "$wid" 9000 4 1 "paused: external setFrame left uncorrected for 1s"

    reel_msg resume >/dev/null
    if [ "$DRY" != 1 ]; then
        [ "$(reel_msg get-status | jq .isPaused)" = "false" ] || fail "resume did not clear isPaused"
        ok "resumed (isPaused=false)"
        # Now Reel must pull the window back onto the strip: its x must leave 9000.
        poll_until 3 "! host_report MAIN | jq -e '.windows[] | select(.id==$wid) | select(.frameCG.x==9000)' >/dev/null" \
            || fail "resume did not correct the window (still at x=9000)"
        waitForSettle
        assertFramesAgree MAIN
        ok "resume corrected the window back onto the strip"
    else
        dry_note "would assert isPaused==false, window leaves x=9000, then frames agree"
    fi
}

sec_reaping() {
    section "health-check reaping — SIGKILLed app's windows disappear ≤1.5s"
    ensure_clean
    # Use the SECOND host so MAIN survives for the persistence section. REAP's
    # pid is already in the allowlist (added at launch).
    host_create REAP 2 >/dev/null
    poll_col_count 5 2 "REAP windows adopted"
    waitForSettle
    if [ "$DRY" != 1 ]; then
        kill -9 "${HOST_PID[REAP]}" 2>/dev/null || true
        unset 'HOST_PID[REAP]'
    else
        dry_echo "kill -9 <REAP pid>"
    fi
    poll_col_count 2 0 "500ms health check reaped the SIGKILLed windows ≤2s"
}

sec_reload_config() {
    section "reload-config — rewriting gap in TOML changes the layout"
    setup_main_windows 2
    local g0; g0="$(group_gap)"
    if [ "$DRY" != 1 ]; then
        write_test_config "$CFG" 64      # was 16 → widen the gap
        reel_msg reload-config >/dev/null
        waitForSettle
        local g1; g1="$(group_gap)"
        [ "$g1" = "64" ] || fail "reload-config did not apply new gap (got $g1, was $g0)"
        ok "reload-config: gap $g0 → $g1"
        write_test_config "$CFG" 16      # restore
        reel_msg reload-config >/dev/null
        waitForSettle
    else
        dry_note "would rewrite gap 16→64, reload-config, assert group_gap==64, then restore"
    fi
    assertFramesAgree MAIN
}

sec_persistence() {
    section "persistence — column order + widths survive a Reel restart"
    setup_main_windows 3
    # Make the state distinctive: widen the active column so restore is observable.
    reel_msg cycle-width-preset >/dev/null; waitForSettle
    local order_before widths_before
    order_before="$(col_window_ids)"
    widths_before="$(reel_msg get-layout | jq -c "[$AG.currentColumns[].cachedWidth]")"

    if [ "$DRY" != 1 ]; then
        info "quitting the test instance (persists snapshot on shutdown)…"
        # Also pins the quit response race: termination used to fire from inside the
        # command handler, before the connection worker wrote the reply, so the
        # response was frequently empty and the exit status meaningless. Now the
        # daemon terminates only after the reply is flushed and the socket closed.
        local quit_out quit_rc
        quit_out="$(reel_msg quit 2>/dev/null)"; quit_rc=$?
        [ "$quit_rc" -eq 0 ] || fail "quit exited $quit_rc, expected 0 (response race?)"
        case "$quit_out" in
            *Quitting*) ;;
            *) fail "quit did not return its response (got '$quit_out')" ;;
        esac
        for _ in $(seq 1 60); do kill -0 "$TEST_REEL_PID" 2>/dev/null || break; sleep 0.05; done
        kill -9 "$TEST_REEL_PID" 2>/dev/null || true
        TEST_REEL_PID=""
        info "relaunching into the SAME namespace…"
        launch_test_reel "$ALLOWLIST"
        assert_sandboxed
        poll_col_count 8 3 "re-adopted 3 windows after restart"
        waitForSettle
        local order_after widths_after
        order_after="$(col_window_ids)"
        widths_after="$(reel_msg get-layout | jq -c "[$AG.currentColumns[].cachedWidth]")"
        [ "$order_after" = "$order_before" ] \
            || fail "column order not restored: $order_before → $order_after"
        [ "$widths_after" = "$widths_before" ] \
            || fail "column widths not restored: $widths_before → $widths_after"
        ok "order + widths restored across restart"
    else
        dry_note "would quit test Reel, relaunch same namespace, assert order=$order_before & widths=$widths_before restored"
    fi
}

# --------------------------- main ------------------------------------------

main() {
    require_confirm

    if [ "$DRY" = 1 ]; then
        info "SMOKE_DRY_RUN=1 — walking sections, validating jq against fixtures, launching nothing"
    fi

    mkdir -p "$NS" "$CFG" "$STATE"
    write_test_config "$CFG" 16
    write_fixtures

    require_binaries

    if [ "$DRY" != 1 ]; then
        stop_live_reel

        # Hosts come up FIRST so their pids can seed the allowlist before Reel
        # launches. Both are created empty; sections populate them on demand.
        info "Starting TestWindowHost helpers…"
        host_start MAIN
        host_start REAP
        # Give the hosts a moment to be schedulable, then read the primary-screen
        # height the MAIN host inferred (it logs it to stderr).
        poll_until 3 "[ -s '$NS/host-MAIN.err' ]" || true
        PRIMARY_H="$(grep -o 'primaryScreenHeight=[0-9.]*' "$NS/host-MAIN.err" 2>/dev/null | head -n1 | cut -d= -f2)"
        info "host-inferred primaryScreenHeight=${PRIMARY_H:-unknown}"

        ALLOWLIST="${HOST_PID[MAIN]},${HOST_PID[REAP]}"
        info "allowlist (REEL_MANAGE_ONLY_PIDS) = $ALLOWLIST"

        launch_test_reel "$ALLOWLIST"
    else
        ALLOWLIST="11111,22222"
        host_start MAIN
        host_start REAP
    fi

    # Split-brain guard BEFORE any window assertion.
    assert_sandboxed

    if [ "$DRY" != 1 ]; then
        # Cross-check: the coordinate origin the host uses (its inferred, or
        # explicitly-passed, primaryScreenHeight) MUST equal the one Reel reports
        # in get-layout — otherwise assertFramesAgree compares apples to oranges.
        PRIMARY_H_REEL="$(reel_msg get-layout | jq -r '.primaryScreenHeight')"
        info "Reel primaryScreenHeight=$PRIMARY_H_REEL (host inferred ${PRIMARY_H:-?})"
        if [ -n "${PRIMARY_H:-}" ] && [ "$PRIMARY_H_REEL" != "null" ]; then
            awk -v a="$PRIMARY_H" -v b="$PRIMARY_H_REEL" 'function d(x){return x<0?-x:x} BEGIN{ if (d(a-b) > 1) exit 3 }' \
                || fail "coordinate-origin mismatch: host primaryScreenHeight=$PRIMARY_H, Reel reports $PRIMARY_H_REEL. assertFramesAgree would be meaningless — run smoke with the primary display active."
            ok "coordinate origins agree (primaryScreenHeight ≈ $PRIMARY_H_REEL)"
        fi
    fi

    # --- run sections (order matters: persistence restarts Reel, so last;
    #     reaping kills REAP which MAIN never depends on) ---
    sec_canary
    sec_focus
    sec_move_column
    sec_width
    sec_close
    sec_echo
    sec_pause_resume
    sec_reaping
    sec_reload_config
    sec_persistence

    section "ALL SMOKE SECTIONS PASSED"
    ok "done"
}

main "$@"
