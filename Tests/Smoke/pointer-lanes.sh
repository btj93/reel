#!/usr/bin/env bash
#
# Tests/Smoke/pointer-lanes.sh — the R6 live lanes: swipes, the pill menu and reorder drags posted through InputPoster
# to a sandboxed ReelNext (and, in lane 1, trunk Reel) managing TestWindowHost windows.
#
# Lane hosts only: it opens real windows, posts synthetic input and, in lane 10, switches Spaces. It refuses to run
# without REEL_E2E_CONFIRM=1 and while any Reel or ReelNext is running.
#
#   REEL_E2E_CONFIRM=1 bash Tests/Smoke/pointer-lanes.sh [lane ...]    lanes 1 to 10, all by default
#   BIN_HEAD=.build/debug/ReelNext BIN_TRUNK=.build/debug/Reel          the binaries under test
#   LANE_OUT=/tmp/swarm-r6/worker-1                                     where screenshots go
#   SMOKE_DRY_RUN=1                                                     walk every lane against fixtures; InputPoster
#                                                                       parses each script and posts nothing
#
# Lane 8 needs two displays. Lane 10 needs two Spaces and Ctrl-Left / Ctrl-Right bound to switching them.

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
BIN_HEAD="${BIN_HEAD:-$BIN_DIR/ReelNext}"
BIN_TRUNK="${BIN_TRUNK:-$BIN_DIR/Reel}"
BIN_REEL="$BIN_HEAD"
NS="/tmp/reel-pointer-lanes-$$"
SOCK="$NS/reel.sock"
CFG="$NS/config"
STATE="$NS/state"
REEL_LOG="$NS/reel.log"
OUT="${LANE_OUT:-$NS/shots}"
TEST_REEL_PID=""

cleanup() {
    quit_reel
    host_quit MAIN
    if [ "${SMOKE_KEEP_NS:-0}" = 1 ]; then warn "kept $NS"; else rm -rf "$NS"; fi
}
trap cleanup EXIT INT TERM

launch_reel() {  # <binary>
    BIN_REEL=$1
    write_test_config "$CFG" 16
    gesture_config "$CFG" "$1"
    : > "$REEL_LOG"
    [ "$DRY" = 1 ] && write_fixture_log
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

# fresh <count> <binary> : a new host with <count> windows under a new instance, settled.
fresh() {
    quit_reel
    host_quit MAIN
    host_start MAIN
    host_create MAIN "$1" >/dev/null
    launch_reel "$2"
    waitForSettle 10
}

shot() {  # <slug>
    mkdir -p "$OUT"
    if [ "$DRY" = 1 ]; then dry_echo "screencapture -x $OUT/$1.png"; return 0; fi
    screencapture -x "$OUT/$1.png"
    ok "saved $OUT/$1.png"
}

# The fixture log a dry run reads instead of ReelNext's, so every parser below runs against the real line shapes.
write_fixture_log() {
    cat >> "$REEL_LOG" <<'EOF'
pointer: scroll tap=true mouse tap=true
pointer: menu tile=1002 pills=Third@600,120;Half@680,120;Two-Thirds@770,120;Full@850,120;Float@920,120;Close@990,120
reorder: trigger session=41 tiles=2 dragged=0 display=1
reorder: ready session=41 reason=captures elapsedMs=120 slots=0:300,2:500 y=140
reorder: hide session=41
EOF
}

log_wait() {  # <timeout> <extended regex> : waits for the line and leaves it in LOG_LINE
    poll_until "$1" "grep -Eq '$2' '$REEL_LOG'" || fail "no log line matching '$2' within $1 s"
    LOG_LINE=$(grep -E "$2" "$REEL_LOG" | tail -1)
}

log_lacks() {  # <extended regex> <message>
    if [ "$DRY" = 1 ]; then dry_note "log lacks '$1': $2"; return 0; fi
    ! grep -Eq "$1" "$REEL_LOG" || fail "$2: found '$1' in the log"
    ok "$2"
}

# Column geometry of the active group, in CG coordinates.
column_field() {  # <index> <jq expression on .frame>
    reel_msg get-layout | jq "$AG.currentColumns[$1].frame | $2"
}
title_x() { column_field "$1" '(.x + .w / 2 | floor)'; }
title_y() { column_field "$1" '(.y + 10 | floor)'; }
center_y() { column_field "$1" '(.y + .h / 2 | floor)'; }
active() { reel_msg get-layout | jq "$AG.activeColumnIndex"; }
view_pos() { reel_msg get-layout | jq "$AG.viewPos"; }

lane1() {
    section "lane 1: the same flick from column 1 of 4 settles on the same column on trunk and head"
    local results=() bin
    for bin in "$BIN_TRUNK" "$BIN_HEAD"; do
        fresh 4 "$bin"
        focus_column 1
        on_display "$(title_x 1)" "$(center_y 1)"
        post "lane1-flick" "$(flick_script "$(title_x 1)" "$(center_y 1)" -30)"
        waitForSettle 10
        results+=("$(active)")
        shot "flick-$(basename "$bin")"
    done
    [ "$DRY" = 1 ] && return 0
    cp "$OUT/flick-$(basename "$BIN_HEAD").png" "$OUT/flick.png"
    [ "${results[1]}" != 1 ] || fail "the flick left head on column 1"
    [ "${results[0]}" = "${results[1]}" ] || fail "trunk settled on column ${results[0]}, head on ${results[1]}"
    ok "both settled on column ${results[1]}"
}

lane2() {
    section "lane 2: a slow drag snaps to the nearest column boundary"
    fresh 4 "$BIN_HEAD"
    local index; index=$(active)
    post "lane2-slow-drag" "$(slow_drag_script "$(title_x "$index")" "$(center_y "$index")" -8)"
    waitForSettle 10
    shot slow-drag
    local off
    off=$(reel_msg get-layout | jq "$AG | (.currentColumns[.activeColumnIndex].frame | .x + .w / 2) - (.regions[0].minX + .regions[0].width / 2) | fabs")
    [ "$DRY" = 1 ] || awk -v d="$off" 'BEGIN { exit !(d <= 2) }' || fail "the active column sits ${off} pt off centre"
    ok "the active column is centred (${off} pt)"
}

lane3() {
    section "lane 3: a flick past the strip's start overshoots and comes back"
    fresh 3 "$BIN_HEAD"
    focus_column 0
    local samples="$NS/lane3-samples"
    : > "$samples"
    post "lane3-bounce" "$(flick_script "$(title_x 0)" "$(center_y 0)" 40)" &
    local poster=$!
    if [ "$DRY" != 1 ]; then
        for _ in $(seq 1 90); do view_pos >> "$samples"; sleep 0.016; done
    fi
    wait "$poster" || fail "lane 3's flick was not posted"
    waitForSettle 10
    shot bounce
    local final; final=$(view_pos)
    [ "$DRY" = 1 ] && { dry_note "pass when samples sit on both sides of the final view position"; return 0; }
    awk -v f="$final" '{ if ($1 > f + 2) above = 1; if ($1 < f - 2) below = 1 } END { exit !(above && below) }' "$samples" \
        || fail "no overshoot around the final view position $final (samples in $samples)"
    ok "the view crossed its rest position and returned to $final"
}

lane4() {
    section "lane 4: a swipe without the modifier leaves the strip alone and reaches the window"
    fresh 3 "$BIN_HEAD"
    local index wid before after count_before count_after
    index=$(active)
    wid=$(reel_msg get-layout | jq "$AG.currentColumns[$index].windowID")
    before=$(view_pos)
    count_before=$(host_report MAIN | jq "[.windows[] | select(.cgWindowID == $wid) | .scrollCount // 0] | add // 0")
    post "lane4-no-modifier" "$(no_modifier_script "$(title_x "$index")" "$(center_y "$index")" -30)"
    sleep 0.5
    after=$(view_pos)
    count_after=$(host_report MAIN | jq "[.windows[] | select(.cgWindowID == $wid) | .scrollCount // 0] | add // 0")
    shot no-modifier
    [ "$DRY" = 1 ] && return 0
    [ "$before" = "$after" ] || fail "the strip moved from $before to $after"
    [ "$count_after" -gt "$count_before" ] || fail "the window got no scroll ($count_before -> $count_after)"
    ok "the strip stayed at $after and the window got $((count_after - count_before)) scroll events"
}

open_menu() {  # <column index> : focuses the column, presses it at (PRESS_X, PRESS_Y); the menu's log line ends up in LOG_LINE
    local wid
    focus_column "$1"
    PRESS_X=$(title_x "$1"); PRESS_Y=$(title_y "$1")
    on_display "$PRESS_X" "$PRESS_Y"
    wid=$(reel_msg get-layout | jq "$AG.currentColumns[$1].windowID")
    post "menu-press-$1" "$(long_press_script "$PRESS_X" "$PRESS_Y")"
    [ "$DRY" = 1 ] && wid=1002
    log_wait 3 "pointer: menu tile=$wid "
}

lane5() {
    section "lane 5: a held modifier press opens the pill menu for the pressed tile"
    fresh 3 "$BIN_HEAD"
    open_menu 1
    shot pill-menu
    post "lane5-dismiss" "$(drag_release_script "$PRESS_X" "$PRESS_Y" "$PRESS_X" $((PRESS_Y + 300)))"
    ok "the menu opened for column 1's window"
}

lane6() {
    section "lane 6: the pill menu closes the tile it opened on after focus moved"
    fresh 3 "$BIN_HEAD"
    local kept closed line close
    kept=$(reel_msg get-layout | jq "$AG.currentColumns[0].windowID")
    closed=$(reel_msg get-layout | jq "$AG.currentColumns[2].windowID")
    open_menu 2
    line=$LOG_LINE
    for _ in 1 2 3; do reel_msg focus-left >/dev/null; done
    [ "$DRY" = 1 ] || [ "$(active)" = 0 ] || fail "focus did not reach column 0"
    close=$(printf '%s' "$line" | sed -E 's/.*Close@([-0-9]+),([-0-9]+).*/\1 \2/')
    read -r cx cy <<< "$close"
    post "lane6-close" "$(drag_release_script "$PRESS_X" "$PRESS_Y" "$cx" "$cy")"
    [ "$DRY" = 1 ] || poll_until 5 "[ \"\$(col_count)\" = 2 ]" || fail "no window closed"
    shot menu-target
    local ids; ids=$(col_window_ids)
    [ "$DRY" = 1 ] && return 0
    printf '%s' "$ids" | jq -e "index($kept) != null and index($closed) == null" >/dev/null || fail "closed the wrong window: $ids"
    ok "window $closed closed and $kept stayed"
}

lane7() {
    section "lane 7: a title-bar drag dropped on gap 3 reorders the columns"
    fresh 4 "$BIN_HEAD"
    local before x y line slot band
    before=$(col_window_ids)
    focus_column 0
    x=$(title_x 0); y=$(title_y 0)
    on_display "$x" "$y"
    post "lane7-drag" "$(drag_start_script "$x" "$y")"
    log_wait 3 'reorder: ready '
    line=$LOG_LINE
    slot=$(printf '%s' "$line" | sed -E 's/.*slots=([^ ]*).*/\1/' | tr ',' '\n' | awk -F: '$1 == 3 { print $2 }')
    band=$(printf '%s' "$line" | sed -E 's/.* y=([-0-9]+).*/\1/')
    [ -n "$slot" ] || slot=$(printf '%s' "$line" | sed -E 's/.*slots=([^ ]*).*/\1/' | tr ',' '\n' | tail -1 | cut -d: -f2)
    post "lane7-drop" "$(drag_release_script $((x + 40)) "$y" "$slot" "$band")"
    log_wait 3 'pointer: drop tile='
    waitForSettle 10
    shot reorder
    local after expected; after=$(col_window_ids)
    expected=$(printf '%s' "$before" | jq -c '.[1:3] + .[0:1] + .[3:]')
    [ "$DRY" = 1 ] && return 0
    [ "$after" = "$expected" ] || fail "order $after, expected $expected"
    ok "order $before became $after"
}

lane8() {
    section "lane 8: a reorder drag on the second display shows the overlay there"
    fresh 3 "$BIN_HEAD"
    local regions second
    regions=$(reel_msg get-layout | jq -c '[.groups[].regions[]]')
    [ "$(printf '%s' "$regions" | jq length)" -ge 2 ] || fail "lane 8 needs two displays"
    # Only the primary display's frame holds the CG origin, so its visible area starts nearest it.
    second=$(printf '%s' "$regions" | jq -c 'sort_by((.minX | fabs) + (.minY | fabs)) | .[1]')
    quit_reel
    local id; id=$(host_window_ids MAIN | awk '{ print $2 }')
    host_cmd MAIN "$(printf '%s' "$second" | jq -c --argjson id "${id:-2}" \
        '{cmd: "setFrame", id: $id, x: (.minX + 100), y: (.minY + 100), w: 700, h: 500}')" | jq -e '.ok == true' >/dev/null \
        || fail "TestWindowHost refused to move window $id onto display $(printf '%s' "$second" | jq .displayID)"
    launch_reel "$BIN_HEAD"
    waitForSettle 10
    local target x y line display
    target=$(reel_msg get-layout | jq -c --argjson r "$second" \
        '[.groups[].currentColumns[].frame | select(.x + .w / 2 >= $r.minX and .x + .w / 2 < $r.maxX)][0] // {x: 728, y: 25, w: 720}')
    x=$(printf '%s' "$target" | jq '(.x + .w / 2 | floor)'); y=$(printf '%s' "$target" | jq '(.y + 10 | floor)')
    on_display "$x" "$y"
    post "lane8-drag" "$(drag_start_script "$x" "$y")"
    log_wait 3 'reorder: trigger '
    line=$LOG_LINE
    display=$(printf '%s' "$line" | sed -E 's/.*display=([0-9]+).*/\1/')
    shot reorder-display2
    post "lane8-release" "$(jq -nc --argjson x $((x + 40)) --argjson y "$y" '[{mouse: "up", x: $x, y: $y, modifier: "fn"}]')"
    [ "$DRY" = 1 ] && return 0
    [ "$display" = "$(printf '%s' "$second" | jq .displayID)" ] || fail "overlay on display $display, cursor on $(printf '%s' "$second" | jq .displayID)"
    ok "the overlay showed on display $display"
}

lane9() {
    section "lane 9: a modifier press in a window's corner resizes natively and starts no reorder"
    fresh 2 "$BIN_HEAD"
    focus_column 0
    local wid before after x y
    wid=$(reel_msg get-layout | jq "$AG.currentColumns[0].windowID")
    before=$(host_report MAIN | jq "[.windows[] | select(.cgWindowID == $wid) | .frameCG.w][0] // 0")
    x=$(( $(column_field 0 '.x | floor') + 3 )); y=$(( $(column_field 0 '.y | floor') + 3 ))
    on_display "$x" "$y"
    post "lane9-corner" "$(corner_script "$x" "$y")"
    sleep 1
    after=$(host_report MAIN | jq "[.windows[] | select(.cgWindowID == $wid) | .frameCG.w][0] // 0")
    shot corner
    log_lacks 'reorder: trigger|pointer: menu ' "no reorder or menu started"
    [ "$DRY" = 1 ] && return 0
    [ "$before" != "$after" ] || fail "the window kept its width $before: no native resize ran"
    ok "the native resize changed the width from $before to $after"
}

switch_space() {  # <key code>: 124 is Ctrl-Right, 123 is Ctrl-Left
    if [ "$DRY" = 1 ]; then dry_echo "osascript key code $1 using control down"; return 0; fi
    osascript -e "tell application \"System Events\" to key code $1 using control down"
    sleep 1.5
}

lane10() {
    section "lane 10: a Space switch mid-drag hides the overlay and keeps the order"
    fresh 3 "$BIN_HEAD"
    local before x y session
    before=$(col_window_ids)
    focus_column 1
    x=$(title_x 1); y=$(title_y 1)
    on_display "$x" "$y"
    post "lane10-drag" "$(drag_start_script "$x" "$y")"
    log_wait 3 'reorder: ready '
    session=$(printf '%s' "$LOG_LINE" | sed -E 's/.*session=([0-9]+).*/\1/')
    switch_space 124
    log_wait 3 "reorder: hide session=$session\$"
    post "lane10-release" "$(jq -nc --argjson x $((x + 40)) --argjson y "$y" '[{mouse: "up", x: $x, y: $y, modifier: "fn"}]')"
    switch_space 123
    waitForSettle 10
    shot reorder-space
    log_lacks 'pointer: drop tile=' "the drag ended without a drop"
    [ "$DRY" = 1 ] && return 0
    [ "$(col_window_ids)" = "$before" ] || fail "order changed from $before to $(col_window_ids)"
    ok "order stayed $before"
}

main() {
    [ "${REEL_E2E_CONFIRM:-}" = 1 ] || { warn "Refusing to run: set REEL_E2E_CONFIRM=1 on a lane host."; exit 2; }
    if [ "$DRY" != 1 ] && { pgrep -x Reel >/dev/null || pgrep -x ReelNext >/dev/null; }; then
        fail "stop the running Reel or ReelNext first"
    fi
    mkdir -p "$NS" "$CFG" "$STATE"
    write_fixtures
    if [ "$DRY" = 1 ]; then
        # Four columns on two displays, so lanes 6 to 8 find the columns and the display they press.
        jq '.groups[0].currentColumns += [.groups[0].currentColumns[] | .index += 2 | .windowID += 2 | .frame.x += 1472]
            | .groups[0].regions += [{displayID: 2, minX: 1440, minY: 0, maxX: 3360, maxY: 1080, width: 1920, height: 1080}]' \
            "$NS/fixture-layout.json" > "$NS/fixture-4.json" && mv "$NS/fixture-4.json" "$NS/fixture-layout.json"
    fi
    local lanes=("$@")
    [ ${#lanes[@]} -gt 0 ] || lanes=(1 2 3 4 5 6 7 8 9 10)
    for lane in "${lanes[@]}"; do "lane$lane"; done
    if [ "$DRY" = 1 ]; then cp -R "$NS/scripts" "${POINTER_SCRIPTS_OUT:-$NS/kept-scripts}" 2>/dev/null || true; fi
    section "pointer lanes ${lanes[*]} passed"
}

main "$@"
