#!/bin/zsh
# Builds build/Bot27.app (release), signed with the local "Bot27 Local Signing" identity if present.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
  tmp=$(mktemp -d)
  swift scripts/make-icon.swift "$tmp/icon.png"
  mkdir "$tmp/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi

APP=build/Bot27.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bot27 "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A stable identity keeps macOS permissions (Accessibility, Screen Recording) across rebuilds;
# ad-hoc signatures change every build. Create it once in the login keychain.
IDENTITY="Bot27 Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"
