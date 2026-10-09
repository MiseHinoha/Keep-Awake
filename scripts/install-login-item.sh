#!/bin/sh
# 让 KeepAwake 登录时自启（LaunchAgent，不需要 root）。
#
# 用法：sh scripts/install-login-item.sh [KeepAwake.app 路径]
# 提示：这一步也要在自己的终端里跑 —— launchctl 的 GUI 域只能在交互式登录会话里引导。
#
# 注意：全角标点紧贴在 $var 后面会被 bash 吞进变量名，一律写成 ${var}。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/KeepAwake.app}"
LABEL="io.github.misehinoha.keepawake"
BIN="$APP/Contents/MacOS/KeepAwake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -x "$BIN" ] || { echo "找不到可执行文件：${BIN}（先跑 scripts/build.sh）" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ 已登记登录自启：${PLIST}"
echo "  撤销：launchctl bootout gui/$(id -u)/$LABEL && rm ${PLIST}"
