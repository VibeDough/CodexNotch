#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION=${1:-}
NOTES_FILE=${2:-}

if [ -z "$VERSION" ] || [ -z "$NOTES_FILE" ]; then
    printf '用法: sh release.sh 0.1.3 release-notes.md\n' >&2
    exit 1
fi
VERSION=${VERSION#v}
case "$VERSION" in
    *[!0-9.]*|'') printf '版本号必须类似 0.1.3\n' >&2; exit 1 ;;
esac
if [ ! -f "$NOTES_FILE" ]; then
    printf '找不到版本说明: %s\n' "$NOTES_FILE" >&2
    exit 1
fi

cd "$ROOT"
if [ "$(git branch --show-current)" != "main" ]; then
    printf '请先切换到 main 分支。\n' >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    printf '请先提交或清理当前改动，再发布版本。\n' >&2
    exit 1
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
    printf 'v%s 已经存在。\n' "$VERSION" >&2
    exit 1
fi

BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" Info.plist
sed -i '' -E "s/CodexNotch-v[0-9.]+-arm64\\.dmg/CodexNotch-v$VERSION-arm64.dmg/g" docs/index.html docs/en/index.html

sh build-app.sh
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R dist/CodexNotch.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="dist/CodexNotch-v$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname CodexNotch -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

git add Info.plist docs/index.html docs/en/index.html
git commit -m "Release v$VERSION"
git push origin main
gh release create "v$VERSION" "$DMG" \
    --repo VibeDough/CodexNotch \
    --title "CodexNotch v$VERSION" \
    --notes-file "$NOTES_FILE" \
    --target main

printf '已发布 CodexNotch v%s\n' "$VERSION"
