#!/bin/sh
# 量顶栏图标落在哪：拿真实 NSStatusItem 渲染出来，把墨迹中心跟菜单栏条带正中比。
#
# 只在两种情况下需要跑：
#   1. 怀疑图标在顶栏里没居中（偏高/偏低、两态大小不一致）；
#   2. 改了 Sources/App/StatusIcon.swift 里的画布尺寸或 verticalNudge。
#
# 为什么要拷成 main.swift：Swift 只允许名为 main.swift 的文件写顶层代码，
# 而这份工具必须和 Sources/App/StatusIcon.swift 一起编译 —— 量的得是 App 真正在用的那份画法。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

cp "${ROOT}/scripts/status-icon-probe.swift" "${TMP}/main.swift"
/usr/bin/swiftc -O "${ROOT}/Sources/App/StatusIcon.swift" "${TMP}/main.swift" -o "${TMP}/status-icon-probe"

set +e
"${TMP}/status-icon-probe"
STATUS=$?
set -e
rm -rf "${TMP}"
exit "${STATUS}"
