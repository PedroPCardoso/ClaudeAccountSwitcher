#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}/.."
cd "$ROOT"
APP="$ROOT/build/Claude Account Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARM_BIN=""
X86_BIN=""
swift build -c release --triple arm64-apple-macosx13.0 --product ClaudeAccountSwitcher >/dev/null 2>&1 && ARM_BIN=$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)
swift build -c release --triple x86_64-apple-macosx13.0 --product ClaudeAccountSwitcher >/dev/null 2>&1 && X86_BIN=$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)
if [[ -n "$ARM_BIN" && -n "$X86_BIN" && -f "$ARM_BIN/ClaudeAccountSwitcher" && -f "$X86_BIN/ClaudeAccountSwitcher" ]]; then
  lipo -create "$ARM_BIN/ClaudeAccountSwitcher" "$X86_BIN/ClaudeAccountSwitcher" -output "$APP/Contents/MacOS/ClaudeAccountSwitcher"
else
  BIN_DIR=$(swift build -c release --product ClaudeAccountSwitcher --show-bin-path)
  cp "$BIN_DIR/ClaudeAccountSwitcher" "$APP/Contents/MacOS/ClaudeAccountSwitcher"
fi
# Companheiro de CLI `cas`, empacotado ao lado do executável da app em Contents/MacOS/.
ARM_CAS=""
X86_CAS=""
swift build -c release --triple arm64-apple-macosx13.0 --product cas >/dev/null 2>&1 && ARM_CAS=$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)
swift build -c release --triple x86_64-apple-macosx13.0 --product cas >/dev/null 2>&1 && X86_CAS=$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)
if [[ -n "$ARM_CAS" && -n "$X86_CAS" && -f "$ARM_CAS/cas" && -f "$X86_CAS/cas" ]]; then
  lipo -create "$ARM_CAS/cas" "$X86_CAS/cas" -output "$APP/Contents/MacOS/cas"
else
  CAS_BIN_DIR=$(swift build -c release --product cas --show-bin-path)
  cp "$CAS_BIN_DIR/cas" "$APP/Contents/MacOS/cas"
fi
chmod 755 "$APP/Contents/MacOS/cas"
cp Resources/claude-launcher "$APP/Contents/Resources/claude-launcher"
cp Resources/claude-account-switcher-logo.png "$APP/Contents/Resources/claude-account-switcher-logo.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Claude Account Switcher</string>
<key>CFBundleExecutable</key><string>ClaudeAccountSwitcher</string>
<key>CFBundleIdentifier</key><string>com.local.ClaudeAccountSwitcher</string>
<key>CFBundleName</key><string>Claude Account Switcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.3.5</string>
<key>CFBundleShortVersionString</key><string>1.3.5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
chmod 755 "$APP/Contents/MacOS/ClaudeAccountSwitcher"
codesign --deep --force --sign - "$APP" >/dev/null
echo "Built $APP"
