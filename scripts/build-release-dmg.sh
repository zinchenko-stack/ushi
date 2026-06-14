#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ushi.xcodeproj"
SCHEME="ushi"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="ushi"
RELEASE_DIR="$ROOT_DIR/release/build"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"
ZIP_PATH="$RELEASE_DIR/$APP_NAME.zip"
LATEST_JSON_PATH="$RELEASE_DIR/latest-mac.json"
ASSETS_DIR="$ROOT_DIR/assets"
BG_SVG="$ASSETS_DIR/dmg-background.svg"
BG_PNG="$ASSETS_DIR/dmg-background.png"
BG_PNG_2X="$ASSETS_DIR/dmg-background@2x.png"
BG_TIFF="$RELEASE_DIR/dmg-background.tiff"

for tool in create-dmg rsvg-convert; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing '$tool'. Install: brew install create-dmg librsvg"
    exit 1
  fi
done

mkdir -p "$RELEASE_DIR"

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

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

if [[ -f "$BG_SVG" ]]; then
  echo "==> Rendering DMG background from SVG"
  rsvg-convert -w 660 -h 470 "$BG_SVG" -o "$BG_PNG"
  rsvg-convert -w 1320 -h 940 "$BG_SVG" -o "$BG_PNG_2X"
fi

echo "==> Building multi-resolution TIFF for retina"
tiffutil -cathidpicheck "$BG_PNG" "$BG_PNG_2X" -out "$BG_TIFF"

echo "==> Cleaning previous artifacts"
rm -f "$DMG_PATH" "$ZIP_PATH" "$LATEST_JSON_PATH"

echo "==> Creating ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating DMG"
create-dmg \
  --volname "$APP_NAME" \
  --background "$BG_TIFF" \
  --window-pos 200 120 \
  --window-size 660 500 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 180 200 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 480 200 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

rm -f "$BG_TIFF"

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

echo ""
echo "Done:"
echo "  DMG: $DMG_PATH"
echo "  ZIP: $ZIP_PATH"
echo "  Manifest: $LATEST_JSON_PATH"
if [[ -z "$BASE_URL" ]]; then
  echo ""
  echo "Tip: set RELEASE_BASE_URL to generate public download URLs in latest-mac.json."
fi
