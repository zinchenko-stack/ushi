#!/bin/zsh
# Сборка Ushi 2.x (бывший UshiNext) для раздачи: ushi.dmg + манифесты обновлений.
#
#   release/build/ushi.dmg          — приложение Ushi.app и ярлык «Программы»
#                                     (окно оформлено: release/dmg/, нужен dmgbuild —
#                                     ставится сам в build/dmg-venv)
#   release/build/latest-mac.json   — манифест для GitHub Release v<версия>:
#                                     его читают Ushi 2.x и старый Ushi 1.x
#   release/build/UshiNext.json     — «мост» для UshiNext 1.0: класть на сайт
#                                     в downloads/ (UshiNext 1.0 смотрит туда)
#
# SKIP_BUILD=1 — не пересобирать приложение, а взять уже собранный Release
# (например, чтобы только переделать окно установщика той же версии).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedDataUshiNextRelease"
RELEASE_DIR="$ROOT_DIR/release/build"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/Ushi.app"
REPO_URL="https://github.com/zinchenko-stack/ushi"
DMG_VENV="$ROOT_DIR/build/dmg-venv"
mkdir -p "$RELEASE_DIR"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  rm -rf "$DERIVED_DATA_DIR/Build/Products/Release/UshiNext.app"
  xcodebuild -project "$ROOT_DIR/ushinext.xcodeproj" -scheme UshiNext \
    -configuration Release -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
  codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

# Оформленное окно установщика: dmgbuild пишет .DS_Store сам, без Finder.
if [[ ! -x "$DMG_VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$DMG_VENV"
  "$DMG_VENV/bin/pip" install -q --disable-pip-version-check "dmgbuild>=1.6,<2"
fi
tiffutil -cathidpicheck "$ROOT_DIR/release/dmg/background.png" \
  "$ROOT_DIR/release/dmg/background@2x.png" -out "$RELEASE_DIR/dmg-background.tiff"
RW_DMG="$RELEASE_DIR/ushi-rw.dmg"
rm -f "$RELEASE_DIR/ushi.dmg" "$RW_DMG"
"$DMG_VENV/bin/dmgbuild" -s "$ROOT_DIR/release/dmg/settings.py" \
  -D app="$APP_PATH" -D background="$RELEASE_DIR/dmg-background.tiff" -D format=UDRW \
  Ushi "$RW_DMG"

# macOS 26.2+ показывает пустое окно вместо фона, если в .DS_Store есть запись
# pBBk (закладка на фон). dmgbuild до 1.6.7 её пишет, а 1.6.7 требует Python 3.10+,
# которого в системе нет. Убираем запись сами: фон всё равно находится по icvp.
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ushi-dmg-mnt.XXXXXX")"
hdiutil attach -nobrowse -noverify -noautoopen -readwrite -mountpoint "$MOUNT_DIR" "$RW_DMG" >/dev/null
"$DMG_VENV/bin/python" - "$MOUNT_DIR/.DS_Store" <<'PY'
import sys
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r+") as d:
    if any(e.filename == "." and e.code == b"pBBk" for e in d):
        d.delete(".", b"pBBk")
with DSStore.open(sys.argv[1], "r") as d:
    if any(e.code == b"pBBk" for e in d):
        sys.exit("pBBk не удалилась из .DS_Store")
PY
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$RELEASE_DIR/ushi.dmg" >/dev/null
rm -f "$RW_DMG"
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
