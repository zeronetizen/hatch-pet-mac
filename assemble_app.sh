#!/bin/bash
# HatchPet macOS 打包脚本：在 macOS 上运行（本机 Linux 只能做 bash -n 语法检查）。
# 流程：swift build universal 二进制 → 组装 HatchPet.app → ad-hoc 签名 → 打 zip。
set -euxo pipefail

cd "$(dirname "$0")"

APP_NAME="HatchPet"
APP="${APP_NAME}.app"
ZIP_NAME="HatchPet-mac.zip"
VIDEOS="hatch.mp4 hatch_working.mp4 hatch_making_something.mp4 hatch_waking.mp4 hatch_milestone_level_up.mp4"

# 1) universal 二进制（arm64 + x86_64）
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
test -x "${BIN}"

# 2) 组装 .app 结构
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Packaging/Info.plist "${APP}/Contents/Info.plist"

# 3) 资源：5 个视频平铺进 Contents/Resources（代码里先查 Bundle.main）
for f in ${VIDEOS}; do
  cp "Sources/HatchPet/Resources/${f}" "${APP}/Contents/Resources/${f}"
done

# 4) SwiftPM 资源包一并放入 Contents/Resources，保证 Bundle.module 回退可用
RES_BUNDLE="$(find .build -name "HatchPet_HatchPet.bundle" -type d | head -n 1 || true)"
if [ -n "${RES_BUNDLE}" ]; then
  cp -R "${RES_BUNDLE}" "${APP}/Contents/Resources/"
  echo "已拷入 SwiftPM 资源包：${RES_BUNDLE}"
else
  echo "警告：未找到 HatchPet_HatchPet.bundle，Bundle.module 回退不可用（Bundle.main 平铺资源不受影响）"
fi

# 5) ad-hoc 签名（自用绕过 Gatekeeper 还需右键打开或去隔离属性，见 README）
codesign --force --deep --sign - "${APP}"
codesign --verify --verbose "${APP}" || true

# 6) 打 zip 产物
rm -f "${ZIP_NAME}"
zip -r "${ZIP_NAME}" "${APP}"
echo "OK: $(pwd)/${ZIP_NAME}"
