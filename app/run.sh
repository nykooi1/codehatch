#!/bin/sh
# Build, wrap it as a Mac app, stop the old copy, start the new one.
cd "$(dirname "$0")" || exit 1
mkdir -p .build
# Built optimised, as a released copy is: an unoptimised build is several times slower at drawing, which shows as lag.
if ! swift build -c release > .build/last-build.log 2>&1; then
  grep -E "error" .build/last-build.log | head -20
  echo "build failed (full log: .build/last-build.log)"
  exit 1
fi
APP=.build/codehatch.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/codehatch "$APP/Contents/MacOS/" && cp Info.plist "$APP/Contents/" && cp Sources/portal.png "$APP/Contents/Resources/" && cp icon/AppIcon.icns "$APP/Contents/Resources/" && cp editor-helper/codehatch-helper-*.vsix "$APP/Contents/Resources/" 2>/dev/null && cp hook/codehatch-hook.sh "$APP/Contents/Resources/"
# The updater (Sparkle) travels inside the app, and the program is told to look for it there.
mkdir -p "$APP/Contents/Frameworks" && ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/codehatch" 2>/dev/null
codesign --force --deep -s - "$APP" >/dev/null 2>&1
pkill -x codehatch 2>/dev/null; sleep 0.3
open -n "$APP" --args "$@"
echo "built and running. stop it with: pkill -x codehatch"
