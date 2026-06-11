#!/bin/zsh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$REPO_ROOT/app/Codex Context Pet Bar.app"
VERSION="0.7"

swiftc "$REPO_ROOT/src/CodexContextPetBar.swift" -o "$APP_PATH/Contents/MacOS/CodexContextPetBar"
cp "$REPO_ROOT/assets/icons/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
mkdir -p "$REPO_ROOT/dist"
rm -f "$REPO_ROOT/dist/Codex Context Pet Bar.zip"
cd "$REPO_ROOT/app"
ditto -c -k --sequesterRsrc --keepParent "Codex Context Pet Bar.app" "$REPO_ROOT/dist/Codex Context Pet Bar.zip"

echo "Release package created:"
echo "$REPO_ROOT/dist/Codex Context Pet Bar.zip"
