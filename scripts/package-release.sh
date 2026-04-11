#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-AIUsage}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AIUsage.xcodeproj}"
SCHEME="${SCHEME:-AIUsage}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$ROOT_DIR/AIUsage/Info.plist}"
VERSION="${1:-${VERSION:-}}"

if [[ -z "${VERSION}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH")"
fi

mkdir -p "$OUTPUT_DIR"

echo "Building ${APP_NAME} ${VERSION}..."

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.zip"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS.dmg"
DMG_STAGING_DIR="$OUTPUT_DIR/dmg-root"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle not found at $APP_PATH" >&2
  exit 1
fi

echo "Ad-hoc signing ${APP_NAME}.app..."
codesign --force --deep -s - "$APP_PATH"
codesign --verify --verbose "$APP_PATH" || true

rm -f "$ZIP_PATH" "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

DMG_RW_PATH="$OUTPUT_DIR/${APP_NAME}-rw.dmg"
rm -f "$DMG_RW_PATH"

DMG_SIZE_KB=$(du -sk "$DMG_STAGING_DIR" | awk '{print $1}')
DMG_SIZE_KB=$(( DMG_SIZE_KB + 10240 ))

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDRW \
  -size "${DMG_SIZE_KB}k" \
  "$DMG_RW_PATH" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW_PATH" \
  | grep "/Volumes/$APP_NAME" | awk -F'\t' '{print $NF}')

echo "Configuring DMG window layout..."
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 640, 400}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "${APP_NAME}.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
hdiutil convert "$DMG_RW_PATH" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW_PATH"
rm -rf "$DMG_STAGING_DIR"

echo "Created release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
