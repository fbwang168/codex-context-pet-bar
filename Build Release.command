#!/bin/zsh
set -e
cd "$(dirname "$0")"

swiftc CodexContextPetBar.swift -o "Codex Context Pet Bar.app/Contents/MacOS/CodexContextPetBar"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.6" "Codex Context Pet Bar.app/Contents/Info.plist"
mkdir -p dist
rm -f "dist/Codex Context Pet Bar.zip"
ditto -c -k --sequesterRsrc --keepParent "Codex Context Pet Bar.app" "dist/Codex Context Pet Bar.zip"

echo "Release package created:"
echo "$(pwd)/dist/Codex Context Pet Bar.zip"
