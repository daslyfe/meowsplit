#!/bin/sh
# Builds "MEOW SPLIT.app" into build/. Pass --install to copy it to /Applications
# and register it with Finder so it shows under Open With for WAV files.
set -e
cd "$(dirname "$0")"
APP="build/MEOW SPLIT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0 Sources/*.swift -o "$APP/Contents/MacOS/MEOW SPLIT"
cp Info.plist "$APP/Contents/Info.plist"
cp -R ui "$APP/Contents/Resources/ui"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep -s - "$APP"
echo "built $APP"

if [ "$1" = "--install" ]; then
  rm -rf "/Applications/MEOW SPLIT.app"
  ditto "$APP" "/Applications/MEOW SPLIT.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/MEOW SPLIT.app"
  echo "installed /Applications/MEOW SPLIT.app"
fi
