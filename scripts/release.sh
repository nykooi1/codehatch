#!/bin/sh
# Make a release: build the app, zip it, sign the zip for the updater, and write the feed the app checks.
#
#   scripts/release.sh 0.1.0 "What changed, in a sentence."
#
# It leaves two files in .build/dist/: codehatch-<version>.zip (upload to a GitHub release with that tag) and
# appcast.xml (publish at https://codehatch.ai/appcast.xml). Once both are up, every installed copy offers the
# update within a day. It uploads nothing itself.
#
# The zip is signed with the update key in your keychain (made once by Sparkle's generate_keys; the matching public
# key is SUPublicEDKey in Info.plist). Lose that key and installed copies can no longer be updated, so back it up:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt   (keep the file somewhere safe)
#
# Signing and notarising, so a downloaded copy opens without the "unidentified developer" warning, use two things
# kept in your keychain, never in this repository:
#   - a "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates), found by name;
#     set CODEHATCH_SIGN_ID to choose one if there are several;
#   - notarisation credentials saved once with:  xcrun notarytool store-credentials codehatch
#     (CODEHATCH_NOTARY_PROFILE to use another name).
# Without the certificate it still makes a release, signed only for this Mac, and says so.
set -e
cd "$(dirname "$0")/.."   # the repository root
VERSION="$1"; NOTES="${2:-Fixes and improvements.}"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [notes]"; exit 1; }
REPO="${CODEHATCH_REPO:-nykooi1/codehatch}"
OUT=.build/dist; APP="$OUT/codehatch.app"; ZIP="$OUT/codehatch-$VERSION.zip"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)   # a number that only goes up; the updater compares these

swift build -c release >/dev/null
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/codehatch" "$APP/Contents/MacOS/"
cp hooks/codehatch-hook.sh assets/AppIcon.icns "$APP/Contents/Resources/" && cp assets/menu-mark.png "$APP/Contents/Resources/portal.png"
cp editor-helper/codehatch-helper-*.vsix "$APP/Contents/Resources/"   # the editor helper travels inside the app
cp Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleName codehatch" "$APP/Contents/Info.plist"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/codehatch" 2>/dev/null || true
# Sign from the inside out, as Apple requires: Sparkle's helpers, then Sparkle, then the app. Hardened runtime on,
# and a secure timestamp, both needed for notarisation.
ID="${CODEHATCH_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
PROFILE="${CODEHATCH_NOTARY_PROFILE:-codehatch}"
if [ -n "$ID" ]; then
  echo "signing with your Developer ID certificate"
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign() { codesign --force --timestamp --options runtime -s "$ID" "$@"; }
  sign "$SP/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  sign "$SP/Autoupdate"
  sign "$SP/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign --entitlements codehatch.entitlements "$APP"
  codesign --verify --deep --strict "$APP"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "sending it to Apple to be notarised (usually a few minutes)"
    ditto -c -k --keepParent "$APP" "$OUT/notarise.zip"
    xcrun notarytool submit "$OUT/notarise.zip" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"   # attaches Apple's approval to the app, so it opens even offline
    rm -f "$OUT/notarise.zip"
    spctl --assess --type execute "$APP" && echo "notarised: macOS will open it without a warning"
  else
    echo "WARNING: no notarisation credentials saved as '$PROFILE'; signed but not notarised (run: xcrun notarytool store-credentials $PROFILE)"
  fi
else
  echo "WARNING: no Developer ID certificate in your keychain; signed for this Mac only. Others will see a warning."
  codesign --force --deep -s - "$APP" >/dev/null 2>&1
fi
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
scripts/make-dmg.sh "$VERSION"
