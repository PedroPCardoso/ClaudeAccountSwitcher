#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
"$ROOT/Scripts/build-app.sh"
DEST="$HOME/Applications/Claude Account Switcher.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/build/Claude Account Switcher.app" "$DEST"
open "$DEST"
echo "App instalada em $DEST. Nenhuma conta foi migrada ou alterada."
