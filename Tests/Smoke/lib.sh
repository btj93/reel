# shellcheck shell=bash
# Tests/Smoke/lib.sh — helpers for the Reel Layer-3 IPC smoke harness.
#
# Sourced by smoke.sh. Contains ONLY reusable, side-effect-light helpers:
# logging, the reel-msg wrapper, the deadline poller, the TestWindowHost
# driver, layout/settle/frame assertions, and the dry-run plumbing. All the
# stateful orchestration (preflight, launch, teardown, the trap) lives in
# smoke.sh so the safety-critical control flow is in one readable place.
#
# Every helper honors SMOKE_DRY_RUN=1: in dry-run mode nothing is launched and
# no window is ever touched. `reel_msg` returns a FIXTURE get-layout/get-status
# payload (so every jq filter in the suite is validated against the REAL nested
# shape), host commands echo a fixture response, and behavioral assertions
# print what they *would* check but never fail. This lets the whole suite be
# walked end-to-end for lint/shape verification without stopping the live WM.

# ---------------------------------------------------------------------------
# Globals expected to be set by smoke.sh before sourcing helpers are used:
#   NS          namespace dir (/tmp/reel-smoke-$$)
#   SOCK        test instance socket path ($NS/reel.sock)
#   CFG         test config dir ($NS/config)
#   STATE       test state dir ($NS/state)
#   BIN_MSG     path to reel-msg binary
#   BIN_HOST    path to TestWindowHost binary
#   BIN_REEL    path to Reel binary
#   REEL_LOG    test instance log file ($NS/reel.log)
#   PRIMARY_H   primary screen height (from get-layout; set after launch)
#   DRY         1 in dry-run mode, 0 otherwise
#   SMOKE_TAG   $$ of the run (used in window title prefixes)
# ---------------------------------------------------------------------------

# jq path to the ACTIVE strip group. get-layout's `.groups` is one entry per
# StripController (per monitor group); we always assert against the group the
# user is currently looking at. On a single-display dev machine there is one
# group and it is active.
AG='.groups | map(select(.isActive)) | .[0]'

# Per-host bookkeeping (bash associative arrays).
declare -A HOST_PID HOST_FD HOST_OUT

# ------------------------------- logging -----------------------------------

_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_grn=$'\033[32m'; _c_red=$'\033[31m'
_c_ylw=$'\033[33m'; _c_cyn=$'\033[36m'; _c_bld=$'\033[1m'

log()      { printf '%s\n' "$*" >&2; }
info()     { printf '%s%s%s\n' "$_c_cyn" "$*" "$_c_reset" >&2; }
ok()       { printf '  %s✓%s %s\n' "$_c_grn" "$_c_reset" "$*" >&2; }
warn()     { printf '%s! %s%s\n' "$_c_ylw" "$*" "$_c_reset" >&2; }
section()  { printf '\n%s━━━ %s%s\n' "$_c_bld" "$*" "$_c_reset" >&2; }
dry_echo() { [ "$DRY" = 1 ] && printf '  %s$ %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; return 0; }
dry_note() { [ "$DRY" = 1 ] && printf '  %s· %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; return 0; }

# fail(): dump diagnostics and abort. Exiting triggers smoke.sh's EXIT trap,
# which relaunches the developer's live Reel. NEVER print into the live session.
fail() {
    printf '\n%s✗ FAIL: %s%s\n' "$_c_red$_c_bld" "$*" "$_c_reset" >&2
    if [ "$DRY" != 1 ]; then
        log "${_c_dim}--- last get-layout ---${_c_reset}"
        REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" get-layout 2>/dev/null | tail -n 120 >&2 || true
        log "${_c_dim}--- tail of test-instance log ($REEL_LOG) ---${_c_reset}"
        tail -n 40 "$REEL_LOG" 2>/dev/null >&2 || true
    fi
    exit 1
}

# ------------------------------- polling -----------------------------------

# poll_until <timeout_seconds> <predicate-string> : eval the predicate every
# 50ms until it succeeds or the deadline passes. The ONE sanctioned wait
# primitive — assertions never sleep-and-hope, they poll a real condition.
poll_until() {
    local to=$1; shift
    if [ "$DRY" = 1 ]; then dry_note "poll_until ${to}s: $*"; return 0; fi
    local end=$(( $(date +%s) + to ))
    while [ "$(date +%s)" -lt "$end" ]; do
        if eval "$@"; then return 0; fi
        sleep 0.05
    done
    return 1
}

# ----------------------------- reel-msg wrapper ----------------------------

# reel_msg <args...> : talk to the TEST instance on the namespaced socket.
# REEL_SOCKET_PATH is pinned so a smoke command can NEVER hit the live socket.
# In dry-run, queries return the embedded fixtures; mutations are echoed only.
reel_msg() {
    if [ "$DRY" = 1 ]; then
        dry_echo "reel-msg $*"
        case "${1:-}" in
            get-layout) cat "$NS/fixture-layout.json" ;;
            get-status) cat "$NS/fixture-status.json" ;;
            *) : ;;
        esac
        return 0
    fi
    REEL_SOCKET_PATH="$SOCK" "$BIN_MSG" "$@"
}

# layout_get : emit the active group's JSON object (validated by every caller).
layout_get() { reel_msg get-layout | jq -c "$AG"; }

# ---------------------------- TestWindowHost driver ------------------------
#
# Each host runs with its stdin fed by a FIFO whose WRITE end we hold open for
# the whole run (so the host never sees stdin EOF, which it treats as "quit").
# stdout is redirected to a growing file; host_cmd sends one JSON line and
# waits for the matching response line (FIFO order is preserved, so the Nth
# request yields the Nth response).

host_start() {  # <name> [primary_height]  — omit height to let the host infer it
    local name=$1 ph=${2:-}
    if [ "$DRY" = 1 ]; then dry_echo "launch TestWindowHost[$name] ${ph:+--primary-height $ph}"; HOST_PID[$name]=0; return 0; fi
    local infifo="$NS/host-$name.in" outfile="$NS/host-$name.out" errfile="$NS/host-$name.err"
    : > "$outfile"; : > "$errfile"
    mkfifo "$infifo"
    local heightArgs=()
    [ -n "$ph" ] && heightArgs=(--primary-height "$ph")
    "$BIN_HOST" "${heightArgs[@]}" --title-prefix "smoke-$SMOKE_TAG-$name" \
        < "$infifo" > "$outfile" 2> "$errfile" &
    HOST_PID[$name]=$!
    local fd
    exec {fd}>"$infifo"    # hold the write end open (keeps host alive)
    HOST_FD[$name]=$fd
    HOST_OUT[$name]=$outfile
}

# host_cmd <name> <json> : send one command, print its one-line JSON response.
#
# Response position is derived from the output file's CURRENT length rather than a
# running counter. Almost every caller reaches this through command substitution
# (`report=$(host_report MAIN)`), which runs in a subshell — so an
# `HOST_RESP[$name]=…` increment there is discarded and the counter drifts behind
# reality, making later calls return an earlier command's response. That produced
# `{"ok":true,"windows":[]}` for a `report` whose real answer was two lines further
# down, and the frames-agree assertion then saw zero host windows.
host_cmd() {
    local name=$1 json=$2
    if [ "$DRY" = 1 ]; then dry_echo "host[$name] <- $json"; _dry_host_response "$json"; return 0; fi
    local out=${HOST_OUT[$name]} fd=${HOST_FD[$name]}
    local before; before=$(wc -l < "$out" | tr -d ' ')
    printf '%s\n' "$json" >&"$fd"
    poll_until 3 "[ \"\$(wc -l < '$out' | tr -d ' ')\" -gt $before ]" \
        || fail "host[$name]: no response to $json"
    # Exactly one response line per command, so the first new line is ours.
    tail -n "+$((before + 1))" "$out" | head -1
}

_dry_host_response() {  # dry-run canned responses keyed by cmd
    case "$1" in
        *'"cmd":"report"'*|*'"cmd": "report"'*) cat "$NS/fixture-report.json" ;;
        *'"cmd":"create"'*|*'"cmd": "create"'*) printf '{"ids":[1,2],"ok":true}\n' ;;
        *) printf '{"ok":true}\n' ;;
    esac
}

host_create() {  # <name> <count> [width] [height]  -> prints created ids (space-sep)
    local name=$1 count=$2 w=${3:-720} h=${4:-600}
    local resp; resp=$(host_cmd "$name" "{\"cmd\":\"create\",\"count\":$count,\"width\":$w,\"height\":$h}")
    printf '%s' "$resp" | jq -r '.ids | @tsv' 2>/dev/null || true
}

host_report() { host_cmd "$1" '{"cmd":"report"}'; }

host_window_ids() {  # <name> -> space-separated live window ids
    host_report "$1" | jq -r '.windows[].id' 2>/dev/null | tr '\n' ' '
}

host_close_all() {  # <name>
    if [ "$DRY" = 1 ]; then dry_echo "host[$1] close all windows"; return 0; fi
    local id
    for id in $(host_window_ids "$1"); do
        host_cmd "$1" "{\"cmd\":\"close\",\"id\":$id}" >/dev/null
    done
}

host_quit() {  # <name>
    if [ "$DRY" = 1 ]; then dry_echo "host[$1] quit"; return 0; fi
    local name=$1
    [ -n "${HOST_PID[$name]:-}" ] || return 0
    local fd="${HOST_FD[$name]:-}"
    # Prefer a graceful protocol quit; fall back to SIGTERM.
    [ -n "$fd" ] && printf '{"cmd":"quit"}\n' >&"$fd" 2>/dev/null || true
    kill -TERM "${HOST_PID[$name]}" 2>/dev/null || true
    # Close the held write-fd (close by numeric value, not the {var} alloc form).
    [ -n "$fd" ] && eval "exec ${fd}>&-" 2>/dev/null || true
    unset 'HOST_PID[$name]'
}

# ------------------------- layout / column assertions ----------------------

col_count() { reel_msg get-layout | jq "$AG.currentColumns | length"; }

active_index() { reel_msg get-layout | jq "$AG.activeColumnIndex"; }

group_gap() { reel_msg get-layout | jq "$AG.gap"; }

# Ordered list of windowIDs across the active strip (column order oracle).
col_window_ids() { reel_msg get-layout | jq -c "[$AG.currentColumns[].windowID]"; }

# Field of the active column: <field> e.g. width / cachedWidth / isFullWidth / presetIndex.
active_col_field() {
    reel_msg get-layout | jq -c "$AG.currentColumns | map(select(.active)) | .[0].$1"
}

assert_col_count() {  # <expected> [message]
    local want=$1 msg=${2:-"column count"}
    local got; got=$(col_count)
    if [ "$DRY" = 1 ]; then dry_note "assert $msg == $want (fixture: $got)"; return 0; fi
    [ "$got" = "$want" ] || fail "$msg: expected $want, got $got"
    ok "$msg == $want"
}

# poll_col_count: wait until the active strip reaches <target> columns.
poll_col_count() {  # <timeout> <target> [message]
    local to=$1 target=$2 msg=${3:-"strip reaches $2 columns"}
    if [ "$DRY" = 1 ]; then col_count >/dev/null; dry_note "$msg (target $target)"; return 0; fi
    poll_until "$to" "[ \"\$(REEL_SOCKET_PATH='$SOCK' '$BIN_MSG' get-layout | jq '$AG.currentColumns | length')\" = '$target' ]" \
        || fail "$msg (timed out; got $(col_count))"
    ok "$msg"
}

# ----------------------------- settle detection ----------------------------
#
# waitForSettle: convergence is duration-agnostic — the strip is "settled" when
# viewPos AND every column frame are byte-identical across 3 consecutive reads
# taken 100ms apart. Animation timing is never hardcoded.
waitForSettle() {  # [timeout_seconds]
    if [ "$DRY" = 1 ]; then
        reel_msg get-layout | jq -ce "$AG | {v: .viewPos, f: [.currentColumns[].frame]}" >/dev/null \
            || fail "waitForSettle jq filter invalid against fixture"
        dry_note "waitForSettle (fixture is static)"; return 0
    fi
    local to=${1:-6} prev="" cur count=0
    local end=$(( $(date +%s) + to ))
    while [ "$(date +%s)" -lt "$end" ]; do
        cur=$(reel_msg get-layout | jq -c "$AG | {v: .viewPos, f: [.currentColumns[].frame]}")
        if [ "$cur" = "$prev" ]; then count=$((count + 1)); else count=0; fi
        prev="$cur"
        [ "$count" -ge 2 ] && return 0   # first read primes prev, then 2 matches = 3 identical
        sleep 0.1
    done
    fail "waitForSettle: strip did not converge within ${to}s"
}

# ------------------------- model-vs-reality assertion ----------------------
#
# assertFramesAgree: for every host window, the frame Reel reports in get-layout
# (CG coords) must match what the window ACTUALLY occupies on screen (host
# `report`, also CG — we launched the host with --primary-height from the same
# get-layout so both sides share the coordinate origin) within ±2px. This is
# the guard against Reel's internal model drifting from reality.
assertFramesAgree() {  # <host_name> [tolerance_px]
    local name=$1 tol=${2:-2}
    local report layout
    report=$(host_report "$name")
    layout=$(reel_msg get-layout)
    # Join host windows to strip columns on CGWindowID (host.cgWindowID ==
    # layout column .windowID) and emit "wid dx dy dw dh" rows.
    local rows
    rows=$(jq -rn \
        --argjson r "$report" \
        --argjson l "$layout" '
        ($l | '"$AG"'.currentColumns
              | map(select(.windowID != 0))
              | map({ (.windowID|tostring): .frame }) | add // {}) as $byWid
        | $r.windows[]
        | ($byWid[(.cgWindowID|tostring)]) as $cf
        | select($cf != null)
        | "\(.cgWindowID) \((.frameCG.x - $cf.x)) \((.frameCG.y - $cf.y)) \((.frameCG.w - $cf.w)) \((.frameCG.h - $cf.h))"
        ')
    if [ "$DRY" = 1 ]; then dry_note "assertFramesAgree($name, ±${tol}px): matched $(printf '%s' "$rows" | grep -c . ) window(s) in fixture"; return 0; fi
    if [ -z "$rows" ]; then
        # Show both sides — "no match" alone gives the reader nothing to act on.
        local host_ids strip_ids
        host_ids=$(printf '%s' "$report" | jq -c '[.windows[].cgWindowID]')
        strip_ids=$(printf '%s' "$layout" | jq -c "[$AG.currentColumns[].windowID]")
        fail "assertFramesAgree($name): no host window matched a strip column by CGWindowID
      host cgWindowIDs : $host_ids
      strip windowIDs  : $strip_ids
      raw host report  : $report
      host stdout tail : $(tail -3 "${HOST_OUT[$name]}" 2>/dev/null | tr '\n' '|')"
    fi
    local wid dx dy dw dh n=0
    while read -r wid dx dy dw dh; do
        [ -n "$wid" ] || continue
        n=$((n + 1))
        awk -v dx="$dx" -v dy="$dy" -v dw="$dw" -v dh="$dh" -v t="$tol" -v w="$wid" \
            'function a(x){return x<0?-x:x} BEGIN{
                if (a(dx)>t || a(dy)>t || a(dw)>t || a(dh)>t) {
                    printf "wid %s diverges: dx=%.1f dy=%.1f dw=%.1f dh=%.1f (tol %s)\n", w, dx, dy, dw, dh, t; exit 3 }}' \
            || fail "$(awk -v dx="$dx" -v dy="$dy" -v dw="$dw" -v dh="$dh" -v w="$wid" 'BEGIN{printf "assertFramesAgree(%s): frame diverged dx=%.1f dy=%.1f dw=%.1f dh=%.1f", w, dx, dy, dw, dh}')"
    done <<< "$rows"
    ok "assertFramesAgree($name): $n window(s) within ±${tol}px of reality"
}

# --------------------------- stability assertions --------------------------

# assert_host_frame_stable: over <seconds>, the window's on-screen x must NOT
# move away from <expected_x> (± tol). Used for the paused-instance negative
# test: a paused Reel must leave a wild external setFrame uncorrected.
assert_host_frame_stable() {  # <host> <win_id> <expected_x> <tol> <seconds> <message>
    local name=$1 wid=$2 ex=$3 tol=$4 secs=$5 msg=$6
    if [ "$DRY" = 1 ]; then
        host_report "$name" | jq -ce ".windows[] | select(.id==$wid) | .frameCG.x" >/dev/null \
            || dry_note "assert_host_frame_stable: (window $wid absent from fixture — filter parsed)"
        dry_note "assert_host_frame_stable: $msg (${secs}s, x≈$ex ±$tol)"; return 0
    fi
    local end=$(( $(date +%s) + secs )) x
    while [ "$(date +%s)" -lt "$end" ]; do
        x=$(host_report "$name" | jq ".windows[] | select(.id==$wid) | .frameCG.x")
        [ -n "$x" ] || fail "$msg: window $wid vanished"
        awk -v x="$x" -v ex="$ex" -v t="$tol" 'function a(v){return v<0?-v:v} BEGIN{ if (a(x-ex) > t) exit 3 }' \
            || fail "$msg: window moved to x=$x (expected to stay near $ex ±$tol)"
        sleep 0.1
    done
    ok "$msg"
}

# --------------------------- config helpers --------------------------------
#
# Write a TEST config.toml. Empty [keybindings] (every action set to "" so the
# parser drops the bundled defaults → ZERO bindings register → the CGEventTap
# consumes nothing, so the smoke instance cannot eat the developer's keys).
# Gestures point at an impossible modifier so no gesture ever fires.
write_test_config() {  # <config_dir> <gap>
    local dir=$1 gap=${2:-16}
    mkdir -p "$dir"
    cat > "$dir/config.toml" <<EOF
# Reel smoke-test config — generated by Tests/Smoke/smoke.sh. Do not edit.
# EVERY keybinding is empty so no hotkey registers and the event tap is inert.
# Gestures are disabled so the test instance never installs a live gesture tap.

[layout]
gap = $gap
snap = ["middle"]
animation_enabled = true

[animation]
scroll_stiffness = 800
scroll_damping_ratio = 1.0
bounce_distance = 40
bounce_damping_ratio = 0.6

[keybindings]
focus_left = ""
focus_right = ""
focus_up = ""
focus_down = ""
move_left = ""
move_right = ""
cycle_width = ""
toggle_full_width = ""
toggle_floating = ""
close_window = ""

[gesture]
modifier = "none"
snap = false

[focus_indicator]
style = "none"
EOF
}

# --------------------------- dry-run fixtures ------------------------------
#
# Fixtures capture the REAL get-layout / get-status / host-report shapes (read
# straight from the get-layout builder in WindowManager.swift and WindowReport
# in TestWindowHost). In dry-run every jq filter in the suite runs against
# these, so a malformed filter or a wrong path fails the walk loudly.
write_fixtures() {
    cat > "$NS/fixture-layout.json" <<EOF
{
  "activeDisplayID": 1,
  "primaryScreenHeight": 900,
  "groups": [
    {
      "groupID": [1],
      "isActive": true,
      "regions": [
        {"displayID": 1, "minX": 0, "minY": 25, "maxX": 1440, "maxY": 900, "width": 1440, "height": 875}
      ],
      "viewPos": 0,
      "workingAreaMinX": 0,
      "workingAreaWidth": 1440,
      "gap": 16,
      "activeColumnIndex": 1,
      "currentSpaceFingerprint": [1001, 1002],
      "currentColumns": [
        {
          "index": 0, "tiles": [1], "windowID": 1001, "bundleID": "co.stransa.smoke", "title": "smoke a",
          "width": "fixed(720.0)", "cachedWidth": 720, "currentAnimatedWidth": 720, "isFullWidth": false,
          "presetIndex": 1, "active": false, "snapIndex": 0, "owningRegionDisplayID": 1,
          "frame": {"x": -8, "y": 25, "w": 720, "h": 600}, "isVisible": true, "isOffScreen": false,
          "regionOverlaps": [{"displayID": 1, "interX": 0, "interW": 712, "area": 427200}]
        },
        {
          "index": 1, "tiles": [2], "windowID": 1002, "bundleID": "co.stransa.smoke", "title": "smoke b",
          "width": "fixed(720.0)", "cachedWidth": 720, "currentAnimatedWidth": 720, "isFullWidth": false,
          "presetIndex": 1, "active": true, "snapIndex": 0, "owningRegionDisplayID": 1,
          "frame": {"x": 728, "y": 25, "w": 720, "h": 600}, "isVisible": true, "isOffScreen": false,
          "regionOverlaps": [{"displayID": 1, "interX": 728, "interW": 712, "area": 427200}]
        }
      ],
      "savedSpaces": []
    }
  ],
  "snapshotStore": []
}
EOF
    cat > "$NS/fixture-status.json" <<EOF
{
  "isPaused": false,
  "version": "0.4.0",
  "socketPath": "$SOCK",
  "configDir": "$CFG",
  "stateDir": "$STATE",
  "managedPids": [11111, 22222]
}
EOF
    cat > "$NS/fixture-report.json" <<EOF
{"ok":true,"windows":[{"id":1,"cgWindowID":1001,"frameCG":{"x":-8,"y":25,"w":720,"h":600},"frameChangeCount":3,"isKey":false},{"id":2,"cgWindowID":1002,"frameCG":{"x":728,"y":25,"w":720,"h":600},"frameChangeCount":3,"isKey":true}]}
EOF
}
