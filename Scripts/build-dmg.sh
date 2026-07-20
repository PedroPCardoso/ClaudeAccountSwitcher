#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
cd "$ROOT"
"$ROOT/Scripts/build-app.sh"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/claude-account-switcher-dmg.XXXXXX")
trap 'rm -R "$STAGING"' EXIT
cp -R "$ROOT/build/Claude Account Switcher.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$ROOT/build"
hdiutil create -volname "Claude Account Switcher" -srcfolder "$STAGING" -ov -format UDZO "$ROOT/build/Claude-Account-Switcher.dmg"
echo "Built $ROOT/build/Claude-Account-Switcher.dmg"
