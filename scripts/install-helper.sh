#!/bin/sh
# 一次性授权：装特权助手 + 写一条只放行它的 sudoers 白名单。
#
# 要在自己的终端里跑 —— 需要交互式输入密码（脚本 / CI 这类非交互会话拿不到 sudo）：
#   sudo sh scripts/install-helper.sh
#
# 可撤销：sudo rm /etc/sudoers.d/keepawake /usr/local/sbin/keepawake-pmset
#
# 注意：全角标点紧贴在 $var 后面会被 bash 吞进变量名，一律写成 ${var}。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER_SRC="$HERE/keepawake-pmset"
[ -f "$HELPER_SRC" ] || HELPER_SRC="$HERE/../packaging/keepawake-pmset"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行：sudo sh $0" >&2
  exit 77
fi
if [ ! -f "$HELPER_SRC" ]; then
  echo "找不到助手脚本：${HELPER_SRC}" >&2
  exit 1
fi

# 授权的对象是「调用 sudo 的那个真人」，不是 root。
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || { echo "拿不到 SUDO_USER，请用 sudo 运行本脚本" >&2; exit 77; }

# 1. 装助手。/usr/local/sbin 必须 root 拥有且不可被他人写入，否则 sudo 有权拒绝执行。
install -d -o root -g wheel -m 755 /usr/local/sbin
install -o root -g wheel -m 755 "$HELPER_SRC" /usr/local/sbin/keepawake-pmset

# 2. 先写临时文件并校验，确认能解析再落地 —— 直接写坏了 sudo 会全线不可用。
TMP="$(mktemp /tmp/keepawake-sudoers.XXXXXX)"
printf '%s\n' \
  "# KeepAwake：只放行这两个精确参数，其他一律拒绝（装于 $(date '+%Y-%m-%d %H:%M'))" \
  "${TARGET_USER} ALL=(root) NOPASSWD: /usr/local/sbin/keepawake-pmset on, /usr/local/sbin/keepawake-pmset off" \
  > "$TMP"
chown root:wheel "$TMP"
chmod 440 "$TMP"
if ! /usr/sbin/visudo -cf "$TMP"; then
  rm -f "$TMP"
  echo "sudoers 文件校验失败，已放弃安装白名单（系统 sudo 未受影响）" >&2
  exit 1
fi
mv "$TMP" /etc/sudoers.d/keepawake

# 3. 自检：用非白名单参数试一次，它必须被拒绝。
if sudo -u "$TARGET_USER" -n /usr/local/sbin/keepawake-pmset bogus 2>/dev/null; then
  echo "✗ 意外：非白名单参数竟然通过了" >&2
  exit 1
fi

echo "✓ 助手已装：/usr/local/sbin/keepawake-pmset"
echo "✓ 白名单已写：/etc/sudoers.d/keepawake（用户 ${TARGET_USER}，仅 on / off）"
echo "  现在回顶栏点一下开关即可，不再要密码。"
echo "  撤销：sudo rm /etc/sudoers.d/keepawake /usr/local/sbin/keepawake-pmset"
