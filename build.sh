#!/bin/zsh
# Build MultiClaude.app and install it to ~/Applications.
set -e
VERSION=${VERSION:-1.1}   # bump with a CHANGELOG.md entry; CI sets it from the tag
BUILD=${BUILD:-2}
cd "${0:A:h}"
APP=build/MultiClaude.app
rm -rf build && mkdir -p $APP/Contents/MacOS
mkdir -p $APP/Contents/Resources
# Universal binary, so the release runs on Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
  swiftc -O -target $ARCH-apple-macos15.0 -o build/MultiClaude-$ARCH main.swift -framework AppKit
done
lipo -create build/MultiClaude-arm64 build/MultiClaude-x86_64 -output $APP/Contents/MacOS/MultiClaude
rm build/MultiClaude-arm64 build/MultiClaude-x86_64
$APP/Contents/MacOS/MultiClaude --export-iconset build/MultiClaude.iconset
iconutil -c icns build/MultiClaude.iconset -o $APP/Contents/Resources/MultiClaude.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MultiClaude</string>
  <key>CFBundleIdentifier</key><string>me.somalabs.multiclaude</string>
  <key>CFBundleExecutable</key><string>MultiClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>MultiClaude</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
(cd build && ditto -c -k --norsrc --noextattr --noqtn --keepParent MultiClaude.app MultiClaude-$VERSION.zip)
[[ "$1" == "--no-install" ]] && { echo "Built build/MultiClaude-$VERSION.zip"; exit 0; }
mkdir -p ~/Applications
pkill -x MultiClaude || true
rm -rf ~/Applications/MultiClaude.app
cp -R $APP ~/Applications/
open ~/Applications/MultiClaude.app
echo "Installed and launched ~/Applications/MultiClaude.app"
