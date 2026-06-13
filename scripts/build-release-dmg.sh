#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ushi.xcodeproj"
SCHEME="ushi"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="ushi"
RELEASE_DIR="$ROOT_DIR/release/build"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
STAGING_DIR="$RELEASE_DIR/dmg-staging"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"
ZIP_PATH="$RELEASE_DIR/$APP_NAME.zip"
LATEST_JSON_PATH="$RELEASE_DIR/latest-mac.json"

mkdir -p "$RELEASE_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "==> Building $APP_NAME.app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found at $APP_PATH"
  exit 1
fi

echo "==> Preparing release artifacts"
rm -f "$DMG_PATH" "$ZIP_PATH" "$LATEST_JSON_PATH"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

APP_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo "1.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo "1")"
BASE_URL="${RELEASE_BASE_URL:-}"
DMG_URL=""
ZIP_URL=""
if [[ -n "$BASE_URL" ]]; then
  BASE_URL="${BASE_URL%/}"
  DMG_URL="$BASE_URL/$APP_NAME.dmg"
  ZIP_URL="$BASE_URL/$APP_NAME.zip"
fi

cat > "$LATEST_JSON_PATH" <<EOF
{
  "appName": "$APP_NAME",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "publishedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "dmgUrl": "$DMG_URL",
  "zipUrl": "$ZIP_URL",
  "notes": "",
  "minimumOSVersion": "macOS 14.0"
}
EOF

rm -rf "$STAGING_DIR"

echo ""
echo "Done:"
echo "  DMG: $DMG_PATH"
echo "  ZIP: $ZIP_PATH"
echo "  Manifest: $LATEST_JSON_PATH"
if [[ -z "$BASE_URL" ]]; then
  echo ""
  echo "Tip: set RELEASE_BASE_URL to generate public download URLs in latest-mac.json."
fi
