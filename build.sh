#!/bin/zsh
# Build MultiClaude.app and install it to ~/Applications.
set -e
VERSION=${VERSION:-1.9}   # bump with a CHANGELOG.md entry; CI sets it from the tag
BUILD=${BUILD:-17}
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
# The multiclaude command line tool (cli/, Go), also universal. It lives in Helpers because the volume
# ignores case, so MacOS/multiclaude would be the app's own MultiClaude executable.
mkdir -p $APP/Contents/Helpers
for ARCH in arm64 amd64; do
  (cd cli && CGO_ENABLED=0 GOOS=darwin GOARCH=$ARCH go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o ../build/multiclaude-$ARCH .)
done
lipo -create build/multiclaude-arm64 build/multiclaude-amd64 -output $APP/Contents/Helpers/multiclaude
rm build/multiclaude-arm64 build/multiclaude-amd64
cp assets/AppIcon.png $APP/Contents/Resources/AppIcon.png
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
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Claude sign-in relay</string>
    <key>CFBundleURLSchemes</key><array><string>claude</string></array>
    <key>LSHandlerRank</key><string>None</string>
  </dict><dict>
    <key>CFBundleURLName</key><string>MultiClaude profile apps</string>
    <key>CFBundleURLSchemes</key><array><string>multiclaude</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>MultiClaude passes Claude's sign-in link to the account window that asked for it.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier me.somalabs.multiclaude.cli $APP/Contents/Helpers/multiclaude
codesign --force --sign - $APP
(cd build && ditto -c -k --norsrc --noextattr --noqtn --keepParent MultiClaude.app MultiClaude-$VERSION.zip)
[[ "$1" == "--no-install" ]] && { echo "Built build/MultiClaude-$VERSION.zip"; exit 0; }
mkdir -p ~/Applications
pkill -x MultiClaude || true
rm -rf ~/Applications/MultiClaude.app
cp -R $APP ~/Applications/
open ~/Applications/MultiClaude.app
# Put the command line tool on the PATH when ~/.local/bin is there (the Homebrew cask links it itself).
if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  mkdir -p ~/.local/bin
  ln -sf ~/Applications/MultiClaude.app/Contents/Helpers/multiclaude ~/.local/bin/multiclaude
  echo "Linked ~/.local/bin/multiclaude"
fi
echo "Installed and launched ~/Applications/MultiClaude.app"
