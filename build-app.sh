#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/dist/CodexNotch.app"

cd "$ROOT"
swift build -c release --jobs 2

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CodexPetNotch" "$APP/Contents/MacOS/CodexPetNotch"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/CodexPetNotch/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

RESOURCE_BUNDLE=$(find -L "$ROOT/.build/release" -maxdepth 1 -type d -name '*CodexPetNotch*.bundle' | head -n 1)
if [ -n "$RESOURCE_BUNDLE" ]; then
    BUNDLE_NAME=$(basename "$RESOURCE_BUNDLE")
    rm -rf "$APP/$BUNDLE_NAME" "$APP/Contents/Resources/$BUNDLE_NAME"
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"
