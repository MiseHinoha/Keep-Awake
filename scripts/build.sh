#!/bin/sh
# 编译 + 组装 .app。零外部依赖：只用 Xcode 命令行工具自带的 swiftc。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/KeepAwake.app"
BIN="$APP/Contents/MacOS/KeepAwake"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
# 助手和它的安装脚本一起塞进 bundle：顶栏弹窗里给出的那条命令，指向的是 app 自己，
# 不依赖仓库放在哪儿。
cp "$ROOT/packaging/keepawake-pmset" "$APP/Contents/Resources/keepawake-pmset"
cp "$ROOT/scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"

# 应用图标是可选的：packaging/AppIcon.icns 在就带上，不在就用系统通用图标。
# 注意它跟顶栏那个图标无关 —— 顶栏用的是 SF Symbol，不吃图片资源；
# 这份 .icns 是给弹窗（NSAlert）、Finder、以及系统设置里的登录项列表看的。
ICON="$ROOT/packaging/AppIcon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
  echo "已带上应用图标：AppIcon.icns"
else
  echo "提示：没有 packaging/AppIcon.icns，本次构建用系统通用图标（可用 scripts/make-icon.sh 生成）"
fi

/usr/bin/swiftc -O \
  "$ROOT/Sources/Core/PowerState.swift" \
  "$ROOT/Sources/App/StatusIcon.swift" \
  "$ROOT/Sources/App/main.swift" \
  -o "$BIN"

# ad-hoc 签名：本机运行足够，也让系统把它当成一个正经的 app bundle（TCC、登录项都要）
/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 \
  || echo "警告：ad-hoc 签名失败（不影响本机运行）"

echo "已构建：$APP"
