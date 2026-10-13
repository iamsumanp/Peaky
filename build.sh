#!/bin/zsh
# Builds Peaky.app and installs it to ~/Applications.  Usage: ./build.sh [--no-install | --dmg]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Peaky.app
echo "› compiling Swift…"
swift build -c release 2>&1 | grep -vE "^(\[|Building|Compiling|Write|Planning)" || true
BIN=$(swift build -c release --show-bin-path)/Peaky
[[ -x $BIN ]] || { echo "build failed"; exit 1; }

mkdir -p build
echo "› compiling peaky CLI…"
swiftc -O tools/peaky-cli.swift -o build/peaky-cli 2>&1 | grep -E "error" || true

echo "› compiling media helper…"
mkdir -p build
clang -dynamiclib -fobjc-arc -O2 -framework Foundation Helper/PeakyMedia.m -o build/PeakyMedia.dylib

if [[ ! -f build/AppIcon.icns ]]; then
  echo "› drawing icon…"
  swiftc -O tools/make-icon.swift -o build/make-icon
  rm -rf build/AppIcon.iconset && build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "› assembling bundle…"
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources}
cp $BIN $APP/Contents/MacOS/Peaky
cp Support/Info.plist $APP/Contents/Info.plist
cp build/PeakyMedia.dylib build/AppIcon.icns $APP/Contents/Resources/
# Optional Pixel fonts (Pixelify Sans, Geist, Geist Mono): drop .ttf files into Fonts/ to use them.
if ls Fonts/*.ttf >/dev/null 2>&1; then mkdir -p $APP/Contents/Resources/Fonts && cp Fonts/*.ttf $APP/Contents/Resources/Fonts/; fi
cp build/peaky-cli $APP/Contents/MacOS/peaky-cli

# Signing. With a self-signed certificate (tools/make-signing-cert.md) macOS keeps Peaky's Calendar /
# Bluetooth / Accessibility permissions across rebuilds; without one it's signed ad-hoc. Override the
# keychain / password / certificate name with PEAKY_SIGN_KEYCHAIN / _PASSWORD / _NAME, or in build.local.sh.
[[ -f build.local.sh ]] && source build.local.sh
KC=${PEAKY_SIGN_KEYCHAIN:-$HOME/Library/Keychains/peaky-signing.keychain-db}
PW=${PEAKY_SIGN_PASSWORD:-peaky-local}
CN=${PEAKY_SIGN_NAME:-Peaky Local Signing}
SIGN=-
if [[ -f $KC ]] && security unlock-keychain -p "$PW" "$KC" 2>/dev/null; then
  ID=$(security find-identity -p codesigning "$KC" | awk -v cn="$CN" 'index($0, cn) {print $2; exit}')
  [[ -n $ID ]] && SIGN=$ID
fi
KCARG=(); [[ $SIGN != - ]] && KCARG=(--keychain "$KC")
codesign --force $KCARG --sign $SIGN --identifier io.github.iamsumanp.peaky.cli $APP/Contents/MacOS/peaky-cli
codesign --force $KCARG --sign $SIGN --identifier io.github.iamsumanp.peaky $APP/Contents/Resources/PeakyMedia.dylib
codesign --force $KCARG --sign $SIGN --identifier io.github.iamsumanp.peaky $APP
[[ $SIGN == - ]] && echo "› signed ad-hoc (permissions may need re-granting)" || echo "› signed with $CN"

if [[ ${1:-} == --dmg ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
  echo "› packing build/Peaky-$VERSION.dmg…"
  STAGE=build/dmg
  rm -rf $STAGE build/Peaky-*.dmg(N)
  mkdir -p $STAGE
  cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
  hdiutil create -volname Peaky -srcfolder $STAGE -fs HFS+ -format UDZO -ov build/Peaky-$VERSION.dmg >/dev/null
  rm -rf $STAGE
  echo "✓ build/Peaky-$VERSION.dmg"
  exit 0
fi

if [[ ${1:-} != --no-install ]]; then
  echo "› installing to ~/Applications…"
  pkill -x Peaky 2>/dev/null && sleep 0.5 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Peaky.app
  cp -R $APP ~/Applications/Peaky.app
  mkdir -p ~/.local/bin
  ln -sf ~/Applications/Peaky.app/Contents/MacOS/peaky-cli ~/.local/bin/peaky
  open ~/Applications/Peaky.app
  echo "✓ Peaky is running (look at your notch)"
fi
