#!/bin/bash
# デーモンとアプリを削除し、ファンを macOS 標準制御に戻す
set -uo pipefail
launchctl bootout gui/$(id -u)/com.necobit.myfancontrol.app 2>/dev/null
rm -f ~/Library/LaunchAgents/com.necobit.myfancontrol.app.plist
pkill -x MyFanControl
sudo launchctl bootout system/com.necobit.myfancontrol 2>/dev/null
sudo /usr/local/libexec/fanctld release 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.necobit.myfancontrol.plist /usr/local/libexec/fanctld
sudo rm -rf "/Library/Application Support/MyFanControl"
rm -rf /Applications/MyFanControl.app
echo "✅ アンインストール完了（ファンは標準制御に戻りました）"
