#!/bin/bash
# Установка FanBar.app + CLI-инструментов fanctl/fanctld.
# Запуск: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Сборка (release)…"
swift build -c release

BIN="$(pwd)/.build/release"
APP="/Applications/FanBar.app"

echo "==> Создание $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanBar"  "$APP/Contents/MacOS/FanBar"
cp "$BIN/fanctld" "$APP/Contents/Resources/fanctld"
cp "$BIN/fanctl"  "$APP/Contents/Resources/fanctl"

# иконка (собирается scripts/make_icon.swift, icns лежит рядом)
if [ -f scripts/FanBar.icns ]; then
    cp scripts/FanBar.icns "$APP/Contents/Resources/FanBar.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>FanBar</string>
    <key>CFBundleDisplayName</key>
    <string>FanBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.fanbar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>FanBar</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>FanBar.icns</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ad-hoc подпись (обязательно для запуска на Apple Silicon)
codesign --force --sign - "$APP"

if [ -S /tmp/fanctl.sock ] && [ -x /usr/local/bin/fanctl ]; then
    /usr/local/bin/fanctl quit >/dev/null 2>&1 || true
fi
sudo launchctl bootout system/local.fanbar.fanctld 2>/dev/null || true

echo "==> CLI в /usr/local/bin (запросит пароль sudo)"
sudo cp "$BIN/fanctl" "$BIN/fanctld" /usr/local/bin/

echo "==> LaunchDaemon local.fanbar.fanctld"
plutil -lint scripts/local.fanbar.fanctld.plist
sudo cp scripts/local.fanbar.fanctld.plist /Library/LaunchDaemons/local.fanbar.fanctld.plist
sudo chown root:wheel /Library/LaunchDaemons/local.fanbar.fanctld.plist
sudo chmod 644 /Library/LaunchDaemons/local.fanbar.fanctld.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/local.fanbar.fanctld.plist

pkill -TERM -f "^$APP/Contents/MacOS/FanBar$" 2>/dev/null || true
sleep 1
open -n "$APP"

echo
echo "Готово."
echo "  Приложение запущено: $APP"
echo "  CLI:         fanctl status | fanctl set 3000 | fanctl auto | fanctl quit"
echo "  Автозапуск приложения при входе:"
echo "    osascript -e 'tell application \"System Events\" to make login item at path \"$APP\"'"
