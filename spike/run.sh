#!/bin/sh
# Build, wrap it as a Mac app (needed for the microphone), stop the old copy, start the new one.
cd "$(dirname "$0")" || exit 1
mkdir -p .build
if ! swift build > .build/last-build.log 2>&1; then
  grep -E "error" .build/last-build.log | head -20
  echo "build failed (full log: .build/last-build.log)"
  exit 1
fi
APP=.build/PortalSpike.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/debug/PortalSpike "$APP/Contents/MacOS/" && cp Info.plist "$APP/Contents/" && cp Sources/portal.png "$APP/Contents/Resources/"
codesign --force -s - "$APP" >/dev/null 2>&1
pkill -x PortalSpike 2>/dev/null; sleep 0.3
open -n "$APP" --args "$@"
echo "built and running. stop it with: pkill -x PortalSpike"
