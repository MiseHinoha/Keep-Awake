#!/bin/sh
# 把一张方形 PNG 切成 macOS 的 .icns，只用系统自带的 sips + iconutil。
# 不依赖 Xcode 工程，也不需要 actool / Assets.car。
#
# 用法：sh scripts/make-icon.sh <方形PNG> [输出路径]
#   默认输出 packaging/AppIcon.icns —— build.sh 看到它就会自动带上。
# 建议源图给 1024x1024：再大是白费，再小放大后会糊。
set -eu

SRC="${1:-}"
if [ -z "${SRC}" ] || [ ! -f "${SRC}" ]; then
  echo "用法：sh scripts/make-icon.sh <方形PNG> [输出路径]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-${ROOT}/packaging/AppIcon.icns}"

# 非正方形会被 sips -z 直接拉伸，这种糊是看不出来的，所以先提醒一句。
WIDTH="$(/usr/bin/sips -g pixelWidth "$SRC" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(/usr/bin/sips -g pixelHeight "$SRC" | awk '/pixelHeight/ {print $2}')"
if [ -n "${WIDTH}" ] && [ -n "${HEIGHT}" ] && [ "${WIDTH}" != "${HEIGHT}" ]; then
  echo "警告：源图不是正方形（${WIDTH}x${HEIGHT}），会被拉伸变形 —— 建议先裁成正方形" >&2
fi

WORK="$(mktemp -d)"
SET="${WORK}/AppIcon.iconset"
mkdir -p "${SET}"

# iconset 的命名是硬性要求：@1x / @2x 成对，缺一个 iconutil 就拒绝生成。
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  pixels="${spec%% *}"
  name="${spec##* }"
  /usr/bin/sips -z "${pixels}" "${pixels}" "$SRC" --out "${SET}/icon_${name}.png" >/dev/null
done

/usr/bin/iconutil -c icns "$SET" -o "$OUT"
rm -rf "${WORK}"
echo "已生成：${OUT}"
