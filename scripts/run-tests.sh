#!/bin/sh
# 跑 Core 层的断言测试（Swift）和特权助手的契约测试（shell）。零依赖。
#
# 注意：全角标点紧贴在 $var 后面会被 bash 吞进变量名（报 unbound variable），
# 所以下面所有「变量后面跟中文标点」的位置一律写成 ${var}。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/packaging/keepawake-pmset"
mkdir -p "$ROOT/build"

echo "— Swift：Core 层纯函数 + 只读集成"
/usr/bin/swiftc \
  "$ROOT/Sources/Core/PowerState.swift" \
  "$ROOT/Tests/main.swift" \
  -o "$ROOT/build/keepawake-tests"
"$ROOT/build/keepawake-tests"

echo "— Shell：特权助手的拒绝契约"
shell_failed=0

expect_status() {
  expected="$1"; shift
  description="$1"; shift
  set +e
  sh "$HELPER" "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    echo "  ✓ ${description}"
  else
    echo "  ✗ ${description}：期望退出码 ${expected}，实际 ${actual}"
    shell_failed=$((shell_failed + 1))
  fi
}

expect_status 64 "无参数被拒绝（64）"
expect_status 64 "非法参数被拒绝（64）" bogus
expect_status 64 "合法参数后带额外内容也被拒绝（64）" on extra
expect_status 77 "合法参数但非 root 时拒绝执行（77）" on

if [ "$shell_failed" -ne 0 ]; then
  echo "✗ ${shell_failed} 项 shell 契约失败"
  exit 1
fi
echo "  ✓ 4 项契约通过"
