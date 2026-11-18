#!/bin/sh
# Make a release: build the app, zip it, sign the zip for the updater, and write the feed the app checks.
#
#   ./release.sh 0.1.0 "What changed, in a sentence."
#
# It leaves two files in .build/dist/: codehatch-<version>.zip (upload to a GitHub release with that tag) and
# appcast.xml (publish at https://codehatch.ai/appcast.xml). Once both are up, every installed copy offers the
# update within a day. It uploads nothing itself.
#
# The zip is signed with the update key in your keychain (made once by Sparkle's generate_keys; the matching public
# key is SUPublicEDKey in Info.plist). Lose that key and installed copies can no longer be updated, so back it up:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt   (keep the file somewhere safe)
#
# Not done here yet: signing with an Apple Developer ID and notarising. Until then a downloaded copy shows the
# "unidentified developer" warning on first launch.
set -e
cd "$(dirname "$0")"
VERSION="$1"; NOTES="${2:-Fixes and improvements.}"
[ -n "$VERSION" ] || { echo "usage: ./release.sh <version> [notes]"; exit 1; }
REPO="${CODEHATCH_REPO:-nykooi1/codehatch}"
OUT=.build/dist; APP="$OUT/codehatch.app"; ZIP="$OUT/codehatch-$VERSION.zip"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)   # a number that only goes up; the updater compares these

swift build -c release >/dev/null
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/codehatch" "$APP/Contents/MacOS/"
cp Sources/portal.png hook/codehatch-hook.sh icon/AppIcon.icns "$APP/Contents/Resources/"
cp editor-helper/codehatch-helper-*.vsix "$APP/Contents/Resources/"   # the editor helper travels inside the app
cp Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleName codehatch" "$APP/Contents/Info.plist"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/codehatch" 2>/dev/null || true
codesign --force --deep -s - "$APP" >/dev/null 2>&1
ditto -c -k --keepParent "$APP" "$ZIP"

SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP")   # prints: sparkle:edSignature="…" length="…"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>codehatch</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/codehatch-$VERSION.zip" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "made $ZIP and $OUT/appcast.xml (version $VERSION, build $BUILD)"
