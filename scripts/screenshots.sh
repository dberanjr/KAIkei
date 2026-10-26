#!/bin/bash
# Regenerates docs/screenshots/*.png from invented data (scripts/make_demo_home.py), never from a real account.
# Needs a release build first: `make build`.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-$HOME/Library/Caches/ClaudeUsageWidget/build}"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ClaudeUsageWidget"
OUT="docs/screenshots"
WORK="$(mktemp -d)"
mkdir -p "$OUT"

# KAIkei only counts a session as open while its process exists, so give the three demo sessions three live pids.
PIDS=()
for _ in 1 2 3; do sleep 600 & PIDS+=($!); done
trap 'kill "${PIDS[@]}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
python3 -I scripts/make_demo_home.py "$WORK/home" "$(IFS=,; echo "${PIDS[*]}")"
export KAIKEI_HOME="$WORK/home"

snap() { local name="$1"; shift; "$BIN" --snapshot "$@" >/dev/null; mv "$WORK/out.png" "$OUT/$name.png"; echo "$OUT/$name.png"; }

snap dashboard-xl            XL "$WORK/out.png"
snap dashboard-xl-dark       XL "$WORK/out.png" dark
snap dashboard-m             M  "$WORK/out.png"
snap session-timeline        XL "$WORK/out.png" drill=session:live height=1080
snap session-timeline-zoom   XL "$WORK/out.png" drill=session:live height=1080 zoom=0.72-0.92
LANES="$(cat "$WORK/home/lanes-session-id")"
# The lane screenshots are only worth taking if the loop session really is the session on disk under that id.
grep -q scheduled_task_fire "$WORK/home/.claude/projects/"*/"$LANES.jsonl" || { echo "demo loop session is missing or was overwritten" >&2; exit 1; }
snap session-lanes           XL "$WORK/out.png" drill=session:"$LANES" height=1500 overlay=output
snap session-lanes-overlay   XL "$WORK/out.png" drill=session:"$LANES" height=1500 overlay=output lanes=on promptlines=on
snap breakdown               XL "$WORK/out.png" drill=total height=1560
snap model-drilldown         XL "$WORK/out.png" drill=model:claude-sonnet-5-5 height=1560

