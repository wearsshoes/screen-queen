#!/bin/bash
# Fast dev loop: rebuild (debug) and relaunch Silkscreen, killing the old instance.
#
#   scripts/dev.sh            # build once, run
#   scripts/dev.sh --watch    # rebuild+relaunch on every source change (needs fswatch)
set -euo pipefail
cd "$(dirname "$0")/.."

run() {
	swift build 2>&1 | grep -vE "^\[|Planning|Compiling|Write |Emitting|Linking|Applying" || true
	# Kill the prior instance and wait for it to actually exit, so we never briefly
	# run two copies (a fast rebuild can start before the old process dies).
	pkill -f "/debug/Silkscreen$" 2>/dev/null || true
	for _ in $(seq 1 20); do pgrep -f "/debug/Silkscreen$" >/dev/null || break; sleep 0.1; done
	# Launch the binary directly (not the .app) so stdout/logs stream to this terminal.
	.build/debug/Silkscreen &
	echo "▸ launched (pid $!) — ⌘⌥F1 or the 🖥 menu-bar item opens the arranger"
}

if [[ "${1:-}" == "--watch" ]]; then
	command -v fswatch >/dev/null || { echo "install fswatch: brew install fswatch"; exit 1; }
	run
	echo "▸ watching Sources/ …"
	fswatch -o -e ".build" Sources | while read -r _; do
		echo "▸ change detected — rebuilding"
		run
	done
else
	run
fi
