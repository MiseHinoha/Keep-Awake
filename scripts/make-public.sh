#!/bin/sh
# 生成一份「可以公开」的快照：只含项目必要的文件，不含工作日志，**完全不动本地仓库**。
#
# 用法：sh scripts/make-public.sh [输出目录]      默认 /tmp/KeepAwake-public
#
# 为什么是"重新做一个初始提交"，而不是把本地历史直接推上去：
# 本地历史里有 .workbuddy/memory 工作日志（记录了其他项目与桌面环境的细节）。
# 只在最新提交里删掉文件是不够的 —— 翻历史照样能看到。所以公开的那份从零开始，
# 本地历史一个字节都不用改，两边互不影响。
#
# 要跳过的路径写在 .gitattributes 的 export-ignore 里（git archive 认它）。
#
# 注意：全角标点紧贴 $var 会被 bash 吞进变量名，一律写成 ${var}。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/KeepAwake-public}"

if [ -e "${OUT}" ]; then
  echo "输出目录已存在，先自己删掉或换个路径：${OUT}" >&2
  exit 1
fi

echo "— 生成公开快照"
mkdir -p "${OUT}"
git -C "${ROOT}" archive --format=tar HEAD | tar -x -C "${OUT}"

git -C "${OUT}" init --quiet -b main
git -C "${OUT}" add -A
git -C "${OUT}" commit --quiet -m 'KeepAwake：合盖保活工具（首次公开）' \
  -m '一个顶栏小工具：切换 macOS 的 pmset SleepDisabled，让 MacBook 合盖后不休眠。'

echo "— 公开前的自检"

FAILED=0

if [ -e "${OUT}/.workbuddy" ]; then
  echo "  ✗ 工作笔记混进来了"; FAILED=1
else
  echo "  ✓ 不含工作笔记"
fi

# 电话号码式的邮箱串（11 位数字直接贴在 @ 前面）。这里故意不写死具体号码 ——
# 这个脚本本身也在公开快照里，写死等于把要过滤的东西又公开一次。
if /usr/bin/grep -r -q -E '[0-9]{11}@' "${OUT}" 2>/dev/null; then
  echo "  ✗ 发现疑似电话号码式邮箱："; /usr/bin/grep -r -n -E '[0-9]{11}@' "${OUT}" || true
  FAILED=1
else
  echo "  ✓ 无电话号码式邮箱"
fi

# 本机绝对路径：含 Keep-Awake 的算文档里的示例（可接受），其他一律算外溢
STRAY="$(/usr/bin/grep -r -h -o -E '/Users/[A-Za-z0-9_./-]+' "${OUT}" 2>/dev/null | /usr/bin/grep -v 'Keep-Awake' || true)"
if [ -n "${STRAY}" ]; then
  echo "  ✗ 发现外溢绝对路径："; printf '%s\n' "${STRAY}" | sort -u; FAILED=1
else
  echo "  ✓ 无外溢绝对路径"
fi

echo "— 快照内容（这些就是要公开的全部）"
git -C "${OUT}" ls-files

if [ "${FAILED}" -ne 0 ]; then
  echo "✗ 自检未通过，先别发布：${OUT}"
  exit 1
fi

echo "✓ 快照就绪：${OUT}（一个初始提交，本地历史未改动）"
echo
echo "要发布时（在快照目录里跑）："
echo "  cd ${OUT} && gh repo create Keep-Awake --public --source=. --push"
echo "  发版： gh release create v<版本> dist/KeepAwake-<版本>.zip dist/KeepAwake-<版本>.dmg --title <版本>"
echo
echo "scripts/check-repo.sh 第 5 项同时接受「没有 remote」与「remote 只指向本项目」——"
echo "开发仓库和公开 clone 都能过，不需要在发布前改脚本。"
