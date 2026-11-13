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

# 3.5) skill 模板：引导页/设置面板导出 skill 包时从 Contents/Resources/skill/ 读
# （v0.18 起两个包：pet-claim 领取包、relay-channel-setup 自建包）
mkdir -p "${APP}/Contents/Resources/skill"
rm -rf "${APP}/Contents/Resources/skill/pet-claim" "${APP}/Contents/Resources/skill/relay-channel-setup"
cp -R skill/pet-claim "${APP}/Contents/Resources/skill/"
cp -R skill/relay-channel-setup "${APP}/Contents/Resources/skill/"
test -f "${APP}/Contents/Resources/skill/pet-claim/SKILL.md"
test -f "${APP}/Contents/Resources/skill/relay-channel-setup/SKILL.md"

# 3.55) 菜单栏图标：Packaging/status-icon{,@2x}.png 平铺进 Contents/Resources
# （Muse idle 形象头部裁切，源图 ~/assets/avatar/reference/hatch.jpg；
# 代码 StatusMenuController 先查 Bundle.main，这两份 PNG 与视频同策略平铺）
cp Packaging/status-icon.png "${APP}/Contents/Resources/status-icon.png"
cp "Packaging/status-icon@2x.png" "${APP}/Contents/Resources/status-icon@2x.png"
test -s "${APP}/Contents/Resources/status-icon.png"
test -s "${APP}/Contents/Resources/status-icon@2x.png"

# 3.6) 应用图标：Packaging/icon-1024.png → iconset（sips）→ AppIcon.icns（iconutil）
ICON_SRC="Packaging/icon-1024.png"
test -f "${ICON_SRC}"
ICONSET="AppIcon.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
sips -z 16 16     "${ICON_SRC}" --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32     "${ICON_SRC}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "${ICON_SRC}" --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64     "${ICON_SRC}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "${ICON_SRC}" --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256   "${ICON_SRC}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "${ICON_SRC}" --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512   "${ICON_SRC}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "${ICON_SRC}" --out "${ICONSET}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SRC}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
test -s "${APP}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET}"
echo "已生成应用图标：${APP}/Contents/Resources/AppIcon.icns"

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
