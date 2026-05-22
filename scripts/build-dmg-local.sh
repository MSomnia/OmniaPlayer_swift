#!/bin/bash
# 本地测试用打包脚本，无需签名证书
# 用法: ./scripts/build-dmg-local.sh [版本号]
set -euo pipefail

VERSION="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build-local"
APP_NAME="Omnia"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
STAGING="${BUILD_DIR}/dmg-staging"
TEMP_DMG="${BUILD_DIR}/temp-rw.dmg"
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> 清理旧构建..."
# 卸载可能残留的同名卷（避免出现 "Omnia 2" 等编号冲突）
for vol in "/Volumes/${APP_NAME}" "/Volumes/${APP_NAME} "*; do
    [ -d "${vol}" ] && hdiutil detach "${vol}" -force -quiet 2>/dev/null || true
done
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ── 第一步：swift build release ──────────────────────────────────────────────
echo "==> swift build -c release..."
cd "${PROJECT_DIR}"
swift build -c release
SWIFT_BUILD_DIR="${PROJECT_DIR}/.build/release"

# ── 第二步：组装 .app Bundle ─────────────────────────────────────────────────
echo "==> 组装 ${APP_NAME}.app..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${SWIFT_BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# SPM 资源 Bundle
[ -d "${SWIFT_BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle" ] && \
    cp -R "${SWIFT_BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle" \
        "${APP_BUNDLE}/Contents/Resources/"

[ -d "${SWIFT_BUILD_DIR}/GRDB_GRDB.bundle" ] && \
    cp -R "${SWIFT_BUILD_DIR}/GRDB_GRDB.bundle" \
        "${APP_BUNDLE}/Contents/Resources/"

# ── 第三步：生成 .icns 图标 ──────────────────────────────────────────────────
echo "==> 生成 AppIcon.icns..."
APPICONSET="${PROJECT_DIR}/Omnia/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET="${BUILD_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"
cp "${APPICONSET}"/*.png "${ICONSET}/"
iconutil -c icns "${ICONSET}" -o "${BUILD_DIR}/AppIcon.icns"
cp "${BUILD_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET}"

# ── 第四步：写入 Info.plist（含 CFBundleIconFile）──────────────────────────
echo "==> 写入 Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.msomnia.omniaplayer</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
PLIST

# ── 第五步：嵌入 VLCKit.framework ────────────────────────────────────────────
echo "==> 嵌入 VLCKit.framework..."
if [ -d "${SWIFT_BUILD_DIR}/VLCKit.framework" ]; then
    cp -R "${SWIFT_BUILD_DIR}/VLCKit.framework" "${APP_BUNDLE}/Contents/Frameworks/"
else
    XCFW="${PROJECT_DIR}/Vendor/VLCKit/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
    [ -d "${XCFW}" ] && cp -R "${XCFW}" "${APP_BUNDLE}/Contents/Frameworks/" \
        || echo "警告：找不到 VLCKit.framework"
fi

# 验证图标已生成
if [ ! -f "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" ]; then
    echo "错误：AppIcon.icns 生成失败，请检查 AppIcon.appiconset 内的 PNG 文件"
    exit 1
fi
echo "    图标: $(ls -lh "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" | awk '{print $5}')"

# ── 第六步：准备 staging 目录 ─────────────────────────────────────────────────
echo "==> 准备 DMG staging..."
mkdir -p "${STAGING}"
cp -R "${APP_BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

# ── 第七步：创建可读写 DMG（-srcfolder 确保内容完整写入）────────────────────
echo "==> 创建 DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDRW \
    "${TEMP_DMG}" -quiet

# 挂载 RW DMG 做 AppleScript 窗口布局
MOUNT_POINT=$(hdiutil attach "${TEMP_DMG}" -readwrite -noverify -noautoopen -plist \
    | python3 -c "
import sys, plistlib
data = plistlib.loads(sys.stdin.buffer.read())
for e in data.get('system-entities', []):
    mp = e.get('mount-point', '')
    if mp.startswith('/Volumes/'):
        print(mp)
        break
")

echo "    挂载点: ${MOUNT_POINT}"

# AppleScript 设置窗口外观
osascript << APPLESCRIPT
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 780, 460}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        delay 1
        try
            set position of item "${APP_NAME}.app" of container window to {140, 175}
            set position of item "Applications" of container window to {440, 175}
        end try
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# 等待 Finder 写完 .DS_Store
sleep 2
sync

hdiutil detach "${MOUNT_POINT}" -quiet

# ── 第八步：转换为压缩只读 DMG ────────────────────────────────────────────────
hdiutil convert "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}" -quiet

rm -f "${TEMP_DMG}"
rm -rf "${STAGING}"

echo ""
echo "======================================================"
echo "完成：${DMG_PATH}"
echo "大小：$(du -sh "${DMG_PATH}" | cut -f1)"
echo ""
echo "安装步骤："
echo "  1. 双击 DMG，将 Omnia 拖到右边的 Applications 文件夹"
echo "  2. 首次打开前在终端执行（去除 Gatekeeper）："
echo "     xattr -rd com.apple.quarantine /Applications/Omnia.app"
echo "======================================================"
