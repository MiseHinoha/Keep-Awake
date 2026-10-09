#!/bin/sh
# 打一个可以直接发给别人的分发包：**zip 和 dmg 两种形式，装的东西一模一样**。
#
# 用法：sh scripts/make-dist.sh
# 产物：dist/KeepAwake-<版本>.zip 与 dist/KeepAwake-<版本>.dmg，并打印各自的 SHA-256
#
# 为什么两种都出：
#   dmg —— macOS 上大家习惯的「安装包」形式：挂载出一个窗口，把 app 拖到 Applications。
#          观感更像正经软件，也不容易让人只拖走半个 bundle。
#   zip —— 更小、不用挂载，命令行 / 脚本分发自取方便，解压即得。
#   两者成本就是多跑一条 hdiutil，所以不做取舍，都留。
#
# 为什么压 zip 用 ditto 而不是 zip 命令：ditto 会保住 .app 的代码签名与扩展属性。
# 用普通 zip 压完再解，签名可能失效 —— 那正是「打开说已损坏」最常见的原因。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${ROOT}/packaging/Info.plist")"
NAME="KeepAwake-${VERSION}"
WORK="$(mktemp -d)"
DIST="${ROOT}/dist"

sh "${ROOT}/scripts/build.sh" >&2
mkdir -p "${DIST}"

# ── 两种形式的暂存目录。dmg 那份多一个指向 /Applications 的符号链接 —— 那就是拖拽目标。
ZIP_STAGE="${WORK}/zip/${NAME}"
DMG_STAGE="${WORK}/dmg/${NAME}"
mkdir -p "${ZIP_STAGE}" "${DMG_STAGE}"
for STAGE in "${ZIP_STAGE}" "${DMG_STAGE}"; do
  cp -R "${ROOT}/build/KeepAwake.app" "${STAGE}/KeepAwake.app"
  cp "${ROOT}/packaging/dist-readme.md" "${STAGE}/安装说明.md"
done
ln -s /Applications "${DMG_STAGE}/Applications"

# zip：先删旧的再压 —— ditto 是往包里追加，不删会留着上一次的条目
rm -f "${DIST}/${NAME}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${ZIP_STAGE}" "${DIST}/${NAME}.zip"

# dmg：UDZO 是压缩只读映像，挂载即用，不会被改坏。
# 卷名不带 .dmg，挂上之后就是 /Volumes/KeepAwake-0.1.0。
rm -f "${DIST}/${NAME}.dmg"
/usr/bin/hdiutil create -quiet -volname "${NAME}" -srcfolder "${DMG_STAGE}" \
  -ov -format UDZO "${DIST}/${NAME}.dmg"

rm -rf "${WORK}"

for FILE in "${DIST}/${NAME}.zip" "${DIST}/${NAME}.dmg"; do
  echo "${FILE}"
  echo "  SHA-256: $(/usr/bin/shasum -a 256 "${FILE}" | awk '{print $1}')"
done
