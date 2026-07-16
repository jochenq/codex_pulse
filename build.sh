#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUT="${ROOT:h}/Codex Pulse Monitor.app"
CONTENTS="$OUT/Contents"

rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
xcrun swiftc -swift-version 5 -O -framework AppKit -framework Foundation -lsqlite3 \
  "$ROOT/CodexPulse.swift" "$ROOT/StatsPanel.swift" -o "$CONTENTS/MacOS/CodexPulse"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/CodexPulseIcon.icns" ]]; then
  cp "$ROOT/Resources/CodexPulseIcon.icns" "$CONTENTS/Resources/CodexPulseIcon.icns"
elif [[ -f "/Applications/Codex Pulse.app/Contents/Resources/CodexPulseIcon.icns" ]]; then
  cp "/Applications/Codex Pulse.app/Contents/Resources/CodexPulseIcon.icns" "$CONTENTS/Resources/CodexPulseIcon.icns"
fi
codesign --force --deep --sign - "$OUT"
echo "$OUT"
