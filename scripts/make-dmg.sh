#!/bin/sh
# Make the download people get from the website: a disk image holding codehatch and a shortcut to Applications,
# so installing is: open it, drag codehatch onto Applications. Signed and notarised like the app.
#
#   scripts/make-dmg.sh 1.0.0      (run after scripts/release.sh, which builds .build/dist/codehatch.app)
#
# The updater keeps using the zip; the disk image is only for first installs.
set -e
cd "$(dirname "$0")/.."
VERSION="$1"; [ -n "$VERSION" ] || { echo "usage: scripts/make-dmg.sh <version>"; exit 1; }
OUT=.build/dist; APP="$OUT/codehatch.app"; DMG="$OUT/codehatch-$VERSION.dmg"
[ -d "$APP" ] || { echo "no $APP; run scripts/release.sh $VERSION first"; exit 1; }
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/codehatch.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "codehatch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
ID="${CODEHATCH_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
PROFILE="${CODEHATCH_NOTARY_PROFILE:-codehatch}"
if [ -n "$ID" ]; then
  codesign --force --timestamp -s "$ID" "$DMG"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "sending the disk image to Apple to be notarised"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG" && echo "notarised: it opens without a warning"
  fi
fi
echo "made $DMG"
