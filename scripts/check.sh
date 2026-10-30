#!/usr/bin/env bash
# Browww regression checks: no XCTest target, no desktop input, no visible windows.
#
#   scripts/check.sh            logic checks; no app build needed
#   scripts/check.sh --native   also real-view checks against the Debug build in .build
set -euo pipefail
cd "$(dirname "$0")/.."

# Native checks give each run an isolated home, which must live under /tmp.
work="$(mktemp -d /tmp/browww-checks.XXXXXX)"
# cfprefsd still creates a preferences file per check domain; delete them afterwards.
domains=(local.browww.check.session-timer)
cleanup() {
  for domain in "${domains[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  rm -rf "$work"
}
trap cleanup EXIT

check() { # name flag sources...
  local name=$1 flag=$2
  shift 2
  echo "▸ $name"
  swiftc -D "$flag" -parse-as-library "$@" -o "$work/$name"
  "$work/$name"
}

check usage-parser OMP_STANDALONE_CHECKS \
  boringNotch/ControlPlane/OmpUsage.swift boringNotch/ControlPlane/OmpUsageProcess.swift \
  boringNotch/ControlPlane/OmpUsageStore.swift Tests/OmpUsageCheck.swift
check calendar-links CALENDAR_STANDALONE_CHECKS \
  boringNotch/models/CalendarModel.swift boringNotch/models/EventModel.swift Tests/CalendarLinkCheck.swift
check drag-lifecycle NOTCH_DRAG_STANDALONE_CHECKS boringNotch/observers/DragDetector.swift Tests/NotchDragCheck.swift
check tab-gestures NOTCH_TAB_SCROLL_STANDALONE_CHECKS boringNotch/extensions/PanGesture.swift Tests/NotchTabScrollCheck.swift
check scroll-routing NOTCH_STANDALONE_CHECKS boringNotch/extensions/PanGesture.swift Tests/NotchScrollCheck.swift
check session-timer SESSION_TIMER_STANDALONE_CHECKS boringNotch/ControlPlane/SessionTimer.swift Tests/SessionTimerCheck.swift

[[ "${1:-}" == --native ]] || exit 0

app="$PWD/.build/Build/Products/Debug/Browww.app/Contents"
if [[ ! -f "$app/MacOS/Browww.debug.dylib" ]]; then
  echo "Build the Debug app into .build first (see README)." >&2
  exit 1
fi
library_guard="(version 1) (allow default) (deny file-write* (subpath \"$HOME/Library\"))"

native() { # name flag source
  local name=$1 flag=$2 source=$3
  local bundle="$work/$name.app/Contents" home="$work/$name-home"
  mkdir -p "$bundle/MacOS" "$home"
  ln -s "$app/Resources" "$bundle/Resources"
  ln -s "$app/Frameworks" "$bundle/Frameworks"
  domains+=("local.browww.check.$name")
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.browww.check.%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>\n' \
    "$name" "$name" > "$bundle/Info.plist"
  echo "▸ $name"
  swiftc -D "$flag" -parse-as-library "$source" "$app/MacOS/Browww.debug.dylib" \
    -I .build/Build/Products/Debug -F "$app/Frameworks" \
    -Xlinker -rpath -Xlinker "$app/MacOS" -Xlinker -rpath -Xlinker "$app/Frameworks" \
    -o "$bundle/MacOS/$name"
  CFFIXED_USER_HOME="$home" HOME="$home" sandbox-exec -p "$library_guard" "$bundle/MacOS/$name"
}

native usage-layout OMP_USAGE_SCROLL_STANDALONE_CHECKS Tests/OmpUsageScrollCheck.swift
native shelf-drag SHELF_DRAG_STANDALONE_CHECKS Tests/ShelfDragCheck.swift
native tab-memory NOTCH_TAB_MEMORY_STANDALONE_CHECKS Tests/NotchTabMemoryCheck.swift
