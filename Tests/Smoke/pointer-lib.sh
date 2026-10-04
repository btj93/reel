# shellcheck shell=bash
# Tests/Smoke/pointer-lib.sh — the InputPoster scripts of the R6 pointer lanes and the perf probe, so trunk and head
# get the same input. Sourced after lib.sh; every builder prints a JSON script in CG coordinates.
#
# `dx` is the trackpad's own horizontal point delta: positive moves the view toward the strip's start.

BIN_POSTER="${BIN_POSTER:-$REPO_ROOT/.build/debug/InputPoster}"

# A modifier flick: six fast samples, the lift, then the trackpad's own momentum tail.
flick_script() {  # <x> <y> <dx>
    jq -nc --argjson x "$1" --argjson y "$2" --argjson dx "$3" '[
        {scroll: "began", x: $x, y: $y, modifier: "fn"},
        {scroll: "changed", x: $x, y: $y, dx: $dx, modifier: "fn", repeat: 6, intervalMs: 8},
        {scroll: "ended", x: $x, y: $y, modifier: "fn"},
        {scroll: "momentum", x: $x, y: $y, dx: ($dx / 2), repeat: 30, intervalMs: 16},
        {scroll: "momentumEnded", x: $x, y: $y}]'
}

# The perf probe's two-second swipe: 120 samples a frame apart, then the lift.
perf_swipe_script() {  # <x> <y> <dx>
    jq -nc --argjson x "$1" --argjson y "$2" --argjson dx "$3" '[
        {scroll: "began", x: $x, y: $y, modifier: "fn"},
        {scroll: "changed", x: $x, y: $y, dx: $dx, modifier: "fn", repeat: 60, intervalMs: 16},
        {scroll: "changed", x: $x, y: $y, dx: (0 - $dx), modifier: "fn", repeat: 60, intervalMs: 16},
        {scroll: "ended", x: $x, y: $y, modifier: "fn"}]'
}

# A slow drag that stops before the lift, so the release carries no velocity.
slow_drag_script() {  # <x> <y> <dx>
    jq -nc --argjson x "$1" --argjson y "$2" --argjson dx "$3" '[
        {scroll: "began", x: $x, y: $y, modifier: "fn"},
        {scroll: "changed", x: $x, y: $y, dx: $dx, modifier: "fn", repeat: 12, intervalMs: 40},
        {waitMs: 250},
        {scroll: "ended", x: $x, y: $y, modifier: "fn"}]'
}

# The flick without the modifier: the app under the cursor must get every sample.
no_modifier_script() {  # <x> <y> <dx>
    flick_script "$1" "$2" "$3" | jq -c 'map(del(.modifier))'
}

# A modifier press on a title bar held past the long press. The button stays down for the next script.
long_press_script() {  # <x> <y>
    jq -nc --argjson x "$1" --argjson y "$2" '[{mouse: "down", x: $x, y: $y, modifier: "fn"}, {waitMs: 600}]'
}

# Drag the held button to (toX, toY) and let go.
drag_release_script() {  # <x> <y> <toX> <toY>
    jq -nc --argjson x "$1" --argjson y "$2" --argjson tx "$3" --argjson ty "$4" '[
        {mouse: "drag", x: $x, y: $y, toX: $tx, toY: $ty, modifier: "fn", repeat: 20, intervalMs: 16},
        {mouse: "up", x: $tx, y: $ty, modifier: "fn"}]'
}

# A modifier press on a title bar dragged 40 points right, past the threshold; the button stays down.
drag_start_script() {  # <x> <y>
    jq -nc --argjson x "$1" --argjson y "$2" '[
        {mouse: "down", x: $x, y: $y, modifier: "fn"},
        {mouse: "drag", x: $x, y: $y, toX: ($x + 40), toY: $y, modifier: "fn", repeat: 8, intervalMs: 16}]'
}

# A modifier press 3 points inside a window's top-left corner, dragged up and left.
corner_script() {  # <x> <y>
    jq -nc --argjson x "$1" --argjson y "$2" '[
        {mouse: "down", x: $x, y: $y, modifier: "fn"},
        {mouse: "drag", x: $x, y: $y, toX: ($x - 60), toY: ($y - 40), modifier: "fn", repeat: 10, intervalMs: 16},
        {mouse: "up", x: ($x - 60), y: ($y - 40), modifier: "fn"}]'
}

# Trunk Reel and ReelNext get the same [gesture] settings, the default config's: the fn modifier with snapping.
gesture_config() {  # <config dir> <binary>
    if [ "$(basename "$2")" = ReelNext ]; then
        printf '\n[gesture]\nmodifier = "fn"\nsnap = true\n' >> "$1/config.toml"
    else
        sed -i '' -e 's/^modifier = "none"$/modifier = "fn"/' -e 's/^snap = false$/snap = true/' "$1/config.toml"
    fi
    grep -q '^modifier = "fn"$' "$1/config.toml" && grep -q '^snap = true$' "$1/config.toml" \
        || fail "$(basename "$2") config lacks modifier = fn and snap = true"
}

# focus_column <index> : make the column active and let the strip settle, so the column sits centred on its display.
focus_column() {
    if [ "$DRY" != 1 ]; then
        while [ "$(active_index)" -gt "$1" ]; do reel_msg focus-left >/dev/null; done
        while [ "$(active_index)" -lt "$1" ]; do reel_msg focus-right >/dev/null; done
    fi
    waitForSettle 10
}

# on_display <x> <y> : fail unless the CG point lies inside some display's visible area. The dry run's fixture does
# not move with focus, so there it only runs the filter.
on_display() {
    local inside
    inside=$(reel_msg get-layout | jq --argjson x "$1" --argjson y "$2" \
        'any(.groups[].regions[]; $x >= .minX and $x < .maxX and $y >= .minY and $y < .maxY)') || fail "on_display filter failed"
    if [ "$DRY" = 1 ]; then dry_note "($1, $2) on a display: $inside"; return 0; fi
    [ "$inside" = true ] || fail "($1, $2) is on no display"
}

# post <name> <json> : save the script under $NS/scripts and post it; a dry run only parses and prints it.
post() {
    local name=$1 json=$2 file="$NS/scripts/$1.json"
    mkdir -p "$NS/scripts"
    printf '%s\n' "$json" > "$file"
    if [ "$DRY" = 1 ]; then
        "$BIN_POSTER" --dry-run "$file" | tail -1 >&2 || fail "InputPoster rejected $name"
        return 0
    fi
    REEL_E2E_CONFIRM=1 "$BIN_POSTER" "$file" >/dev/null || fail "InputPoster could not post $name"
}
