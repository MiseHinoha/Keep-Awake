#!/bin/sh
# 切换应用图标配色，并把三版都归档下来 —— 轮换只需要再来一次。
#
# 用法：
#   sh scripts/switch-icon.sh warm|cold|dark   渲染该版 → 归档 → 生成 icns → 重建 → 重启顶栏
#   sh scripts/switch-icon.sh all              只把三版一起渲染归档，不动当前生效的那版
#   sh scripts/switch-icon.sh list             看当前生效的是哪一版
#
# 为什么归档的是 PNG 而不是 .icns：三张 PNG 加起来才几百 KB，而 .icns 每版都有近 1MB，
# 且它完全由 PNG 决定 —— 需要时现生成（一条 iconutil 的事），没必要让仓库背着三份二进制。
#
# 三版配色（定义在 packaging/draw-icon.swift 里）：
#   warm 橙→深橙（app 原本的品牌色）  cold 浅蓝→深蓝（冰饮）  dark 深灰蓝→近黑（对比最强）
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANTS="${ROOT}/packaging/icon-variants"
SOURCE="${ROOT}/packaging/AppIcon-source.png"
ICNS="${ROOT}/packaging/AppIcon.icns"
APP="${ROOT}/build/KeepAwake.app"
BIN="${APP}/Contents/MacOS/KeepAwake"

usage() {
  echo "用法：sh scripts/switch-icon.sh warm|cold|dark|all|list" >&2
  exit 64
}

render_binary() {
  # swiftc 的输出一律走 stderr —— 这个函数的 stdout 只有一行「可执行文件路径」，
  # 被 command substitution 取走，混进别的字样就会当成路径用。
  TMPBIN="$(mktemp -d)/draw-icon"
  /usr/bin/swiftc -O -parse-as-library "${ROOT}/packaging/draw-icon.swift" -o "${TMPBIN}" >&2
  echo "${TMPBIN}"
}

# 归档：三版都渲染一遍，缺谁补谁。改配色就改 draw-icon.swift，然后 all 重新归档。
archive_all() {
  mkdir -p "${VARIANTS}"
  BINDIR="$(render_binary)"
  for name in warm cold dark; do
    # 主语在仓库根目录，draw-icon 从里面找 packaging/glass-subject.png
    (cd "${ROOT}" && "${BINDIR}" "${VARIANTS}/AppIcon-${name}.png" "${name}")
  done
  echo "已归档三版：${VARIANTS}"
}

current_variant() {
  # 拿源图跟三个归档比内容：谁一模一样，谁就是当前生效的。
  # 用 cmp 而不是记录状态文件 —— 少一个可能过期的真相来源。
  [ -f "${SOURCE}" ] || { echo "未装"; return; }
  for name in warm cold dark; do
    if [ -f "${VARIANTS}/AppIcon-${name}.png" ] && /usr/bin/cmp -s "${SOURCE}" "${VARIANTS}/AppIcon-${name}.png"; then
      echo "${name}"
      return
    fi
  done
  echo "未知（源图与三版归档都不一致）"
}

# 只重启我们自己那个 app：先按二进制全路径圈出候选 PID，再逐条核对 ps 的 command 必须
# 与之一字不差才 kill。任何宽匹配（pkill -f KeepAwake 之类）都不许用 —— 这台机器上
# 别人的渲染进程就是这么被误伤过的。
restart_app() {
  [ -x "${BIN}" ] || return 0
  for pid in $(/usr/bin/pgrep -f -- "${BIN}" || true); do
    CMD="$(/bin/ps -o command= -p "${pid}" 2>/dev/null || true)"
    if [ "${CMD}" = "${BIN}" ]; then
      kill "${pid}"
      echo "已停掉旧实例 PID ${pid}"
    fi
  done
  # 等它退干净再开新的，否则旧实例可能把新的顶掉
  sleep 1
  /usr/bin/open "${APP}"
  echo "已重启：${APP}"
}

case "${1:-}" in
  list)
    echo "当前生效：$(current_variant)"
    echo "归档目录：${VARIANTS}"
    /bin/ls -1 "${VARIANTS}" 2>/dev/null || echo "（还没有归档，先跑一次 all）"
    exit 0
    ;;
  all)
    archive_all
    echo "当前生效：$(current_variant)"
    exit 0
    ;;
  warm|cold|dark) VARIANT="$1" ;;
  *) usage ;;
esac

archive_all

cp "${VARIANTS}/AppIcon-${VARIANT}.png" "${SOURCE}"
sh "${ROOT}/scripts/make-icon.sh" "${SOURCE}"
sh "${ROOT}/scripts/build.sh"

# 让 Finder / 系统设置里的图标缓存认账（bundle id 变了名字才会变）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "${APP}" >/dev/null 2>&1 || true

echo "已切到 ${VARIANT} 版"
restart_app

if [ -x "${ROOT}/scripts/check-repo.sh" ]; then
  sh "${ROOT}/scripts/check-repo.sh" >/dev/null && echo "边界自检通过"
fi
