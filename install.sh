#!/bin/bash
# ビルドしてデーモン・メニューバーアプリをインストールする
set -euo pipefail
cd "$(dirname "$0")"

if pgrep -x "Macs Fan Control" >/dev/null; then
    echo "⚠️  Macs Fan Control が起動中です。競合するので終了してから再実行してください。"
    exit 1
fi

swift build -c release
BIN=.build/release

# アプリバンドル作成
APP=/Applications/MyFanControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/MyFanControl" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

# デーモン（root）
sudo launchctl bootout system/com.necobit.myfancontrol 2>/dev/null || true
sudo mkdir -p /usr/local/libexec
sudo install -m 755 -o root -g wheel "$BIN/fanctld" /usr/local/libexec/fanctld
sudo install -m 644 -o root -g wheel Resources/com.necobit.myfancontrol.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.necobit.myfancontrol.plist

# ログイン時にメニューバーアプリを起動
mkdir -p ~/Library/LaunchAgents
cp Resources/com.necobit.myfancontrol.app.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.necobit.myfancontrol.app 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.necobit.myfancontrol.app.plist

echo "✅ インストール完了。ログ: /var/log/myfancontrol.log"
