#!/bin/sh
# 仓库边界自检：Keep-Awake 必须是一个独立、不串仓库、不外溢的仓库。
#
# 为什么需要它：这一轮的真实教训是「新开一个项目」有两层（代码仓库 + 桌面 Project），
# 而「串仓库」正是同一类错误的下一次翻版 —— 一个 cd 之后，git add 就可能落在别人家里。
# 所以把边界写成可复核的断言，每次动手前花 50 毫秒跑一遍，而不是靠人记得。
#
# 注意：全角标点紧贴 $var 会被 bash 吞进变量名，一律写成 ${var}。
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
GIT="git -C ${HERE}"
FAILED=0

fail() { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
ok() { echo "  ✓ $1"; }

echo "— Keep-Awake 仓库边界自检"

# 1. 调用方不能站在别的仓库里 —— 这是「串」最真实的入口
CALLER="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "${CALLER}" ] && [ "${CALLER}" != "${HERE}" ]; then
  fail "调用方在另一个仓库里：${CALLER}（本脚本只能从 Keep-Awake 内部调用）"
else
  ok "调用方不在别的仓库内"
fi

# 2. 仓库根就是本目录（而不是某个外层仓库的子目录）
TOP="$(${GIT} rev-parse --show-toplevel)"
[ "${TOP}" = "${HERE}" ] && ok "仓库根 = ${HERE}" || fail "仓库根异常：${TOP}"

# 3. 外层目录不能有 .git —— 否则本仓库会被当成别人的未跟踪子目录
#    路径一律用 pwd -P 解析过（下面的 HERE、上面的 toplevel）：/tmp 这类符号链接目录
#    会让「逻辑路径」和 git 报出的物理路径对不上，凭空判出「串仓库」。
OUTER=""
CURSOR="$(dirname "${HERE}")"
while [ "${CURSOR}" != "/" ]; do
  [ -e "${CURSOR}/.git" ] && OUTER="${CURSOR}"
  CURSOR="$(dirname "${CURSOR}")"
done
[ -z "${OUTER}" ] && ok "外层无嵌套 .git" || fail "外层存在仓库：${OUTER}"

# 4. 分支
BRANCH="$(${GIT} branch --show-current)"
[ "${BRANCH}" = "main" ] && ok "分支 = main" || fail "当前分支是 ${BRANCH}（期望 main）"

# 5. 远端只允许指向本项目自己的仓库 —— 开发仓库可以一个 remote 都没有，
#    对外那份有且只有这一个。判定看「仓库名」而不是主机/账号：fork、SSH 写法、
#    换到别的托管平台都应该过；指向别的项目的任何 remote 都算「串」。
REMOTE_URLS="$(${GIT} remote -v | awk '{print $2}' | sort -u)"
BAD_REMOTES=""
for URL in ${REMOTE_URLS}; do
  printf '%s\n' "${URL}" | grep -q -E '[:/][^/]+/[Kk]eep-?[Aa]wake(\.git)?$' || BAD_REMOTES="${BAD_REMOTES} ${URL}"
done
if [ -z "${BAD_REMOTES}" ]; then
  ok "remote 只指向本项目（或没有 remote）"
else
  fail "存在指向别处的 remote：${BAD_REMOTES}"
fi

# 6. 构建产物必须被忽略，不能混进提交
if ${GIT} check-ignore -q build/; then ok "build/ 已忽略"; else fail "build/ 未被忽略"; fi
if ${GIT} ls-files --error-unmatch build/KeepAwake.app >/dev/null 2>&1; then
  fail "构建产物被打进了版本库"
else
  ok "构建产物未入版本库"
fi

# 7. 没有指向仓库外的符号链接
LINKS="$(find "${HERE}" -type l -not -path "${HERE}/build/*" -print || true)"
[ -z "${LINKS}" ] && ok "无符号链接" || fail "发现符号链接：${LINKS}"

# 8. 被跟踪的文件里不得写死别的项目的绝对路径（那是最隐蔽的一种「串」）
HITS="$(${GIT} grep -h -o -E '/Users/[A-Za-z0-9_./-]+' -- . || true)"
STRAY="$(printf '%s\n' "${HITS}" | grep -v 'Keep-Awake' | grep -v '^$' || true)"
[ -z "${STRAY}" ] && ok "无外溢绝对路径" || fail "发现外溢路径：${STRAY}"

# 9. 提交身份（信息项：确认不会用错身份提交到别的项目）
echo "  · 提交身份：$(${GIT} config user.name) <$(${GIT} config user.email)>"

if [ "${FAILED}" -ne 0 ]; then
  echo "✗ ${FAILED} 项边界检查失败"
  exit 1
fi
echo "  ✓ 8 项边界检查通过"
