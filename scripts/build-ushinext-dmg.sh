#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedDataUshiNextRelease"
RELEASE_DIR="$ROOT_DIR/release/build"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/UshiNext.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ushinext-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$RELEASE_DIR"
xcodebuild -project "$ROOT_DIR/ushinext.xcodeproj" -scheme UshiNext \
  -configuration Release -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto "$APP_PATH" "$STAGING_DIR/UshiNext.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname UshiNext -srcfolder "$STAGING_DIR" \
  -format UDZO -ov "$RELEASE_DIR/UshiNext.dmg"
hdiutil verify "$RELEASE_DIR/UshiNext.dmg"
shasum -a 256 "$RELEASE_DIR/UshiNext.dmg" > "$RELEASE_DIR/UshiNext.dmg.sha256"

# Манифест своего канала обновлений: UshiNext проверяет его на сайте
# (https://ushi.zinchenko.cc/downloads/UshiNext.json) — класть рядом с DMG.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
cat > "$RELEASE_DIR/UshiNext.json" <<JSON
{
  "appName": "UshiNext",
  "version": "$VERSION",
  "build": "$BUILD",
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "dmgUrl": "https://ushi.zinchenko.cc/downloads/UshiNext.dmg",
  "notes": ""
}
JSON
echo "Manifest: $RELEASE_DIR/UshiNext.json (version $VERSION)"
echo "DMG: $RELEASE_DIR/UshiNext.dmg"
