#!/bin/zsh
# Сборка Ushi 2.x (бывший UshiNext) для раздачи: ushi.dmg + манифесты обновлений.
#
#   release/build/ushi.dmg          — приложение Ushi.app и ярлык «Программы»
#   release/build/latest-mac.json   — манифест для GitHub Release v<версия>:
#                                     его читают Ushi 2.x и старый Ushi 1.x
#   release/build/UshiNext.json     — «мост» для UshiNext 1.0: класть на сайт
#                                     в downloads/ (UshiNext 1.0 смотрит туда)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedDataUshiNextRelease"
RELEASE_DIR="$ROOT_DIR/release/build"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/Ushi.app"
REPO_URL="https://github.com/zinchenko-stack/ushi"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ushi-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$RELEASE_DIR"
rm -rf "$DERIVED_DATA_DIR/Build/Products/Release/UshiNext.app"
xcodebuild -project "$ROOT_DIR/ushinext.xcodeproj" -scheme UshiNext \
  -configuration Release -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto "$APP_PATH" "$STAGING_DIR/Ushi.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname Ushi -srcfolder "$STAGING_DIR" \
  -format UDZO -ov "$RELEASE_DIR/ushi.dmg"
hdiutil verify "$RELEASE_DIR/ushi.dmg"
shasum -a 256 "$RELEASE_DIR/ushi.dmg" > "$RELEASE_DIR/ushi.dmg.sha256"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DMG_URL="$REPO_URL/releases/download/v$VERSION/ushi.dmg"

# appName: Ushi 2.x принимает только «Ushi»; старый Ushi 1.x поле не проверяет.
cat > "$RELEASE_DIR/latest-mac.json" <<JSON
{
  "appName": "Ushi",
  "version": "$VERSION",
  "build": "$BUILD",
  "publishedAt": "$PUBLISHED",
  "dmgUrl": "$DMG_URL",
  "notes": "",
  "minimumOSVersion": "macOS 14.6"
}
JSON

# UshiNext 1.0 принимает только appName «UshiNext» и смотрит на сайт.
cat > "$RELEASE_DIR/UshiNext.json" <<JSON
{
  "appName": "UshiNext",
  "version": "$VERSION",
  "build": "$BUILD",
  "publishedAt": "$PUBLISHED",
  "dmgUrl": "$DMG_URL",
  "notes": ""
}
JSON

echo "Version: $VERSION ($BUILD)"
echo "DMG: $RELEASE_DIR/ushi.dmg"
echo "Manifests: $RELEASE_DIR/latest-mac.json, $RELEASE_DIR/UshiNext.json"
