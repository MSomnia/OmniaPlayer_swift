# OmniaPlayer macOS DMG 打包指南

## 概览

OmniaPlayer 是一个纯 Swift Package Manager (SPM) 项目，打包为 `.app` Bundle 再制作成 `.dmg` 分发包。核心依赖有三个，必须全部打进 Bundle：

| 依赖 | 来源 | 打包方式 |
|------|------|----------|
| **VLCKit.framework** | `Vendor/VLCKit/VLCKit.xcframework` | 嵌入 `Contents/Frameworks/` |
| **NeteaseCloudMusicApi** | npm 包 + Node.js runtime | 放入 `Contents/Resources/NeteaseCloudMusicApi/` |
| **Node.js 二进制** | nodejs.org | 放入 `Contents/MacOS/node` |

最终 Bundle 结构：

```
Omnia.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   ├── Omnia                        ← 主可执行文件
    │   └── node                         ← 打包的 Node.js 二进制
    ├── Frameworks/
    │   └── VLCKit.framework/            ← VLC 播放引擎
    └── Resources/
        ├── *.bundle                     ← SPM 资源包（GRDB 等）
        └── NeteaseCloudMusicApi/        ← 网易云 API 运行时
            ├── app.js
            └── node_modules/
```

---

## 前置条件

### 工具

```bash
# Xcode Command Line Tools
xcode-select --install

# Homebrew（用于 create-dmg）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# create-dmg
brew install create-dmg

# Node.js（用于准备 NeteaseCloudMusicApi 包）
brew install node
```

### Apple Developer 账号

需要配置两项用于代码签名和公证：

- **Apple ID** 及 App-Specific Password（用于公证）
- **Developer ID Application** 证书（用于代码签名，非 App Store 分发）

检查已安装证书：

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

输出示例：
```
1) ABCDEF1234567890 "Developer ID Application: Your Name (TEAMID)"
```

记录 `TEAMID` 和证书名称，后续步骤会用到。

---

## 第一步：版本号配置

SPM executable target 需要手动创建 `Info.plist`。在项目根目录新建 `Omnia/Resources/Info.plist`（首次打包时执行，后续只需更新版本号）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.msomnia.omniaplayer</string>
    <key>CFBundleName</key>
    <string>Omnia</string>
    <key>CFBundleDisplayName</key>
    <string>Omnia</string>
    <key>CFBundleExecutable</key>
    <string>Omnia</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 MSomnia. All rights reserved.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
```

> 每次发版前修改 `CFBundleShortVersionString`（语义版本，如 `1.0.1`）和 `CFBundleVersion`（递增整数，如 `2`）。

---

## 第二步：准备 NeteaseCloudMusicApi 运行时

这是打包流程中最复杂的部分。需要将 Node.js binary 和 NeteaseCloudMusicApi npm 包捆绑进 app。

### 2a. 下载 Node.js 二进制（通用架构）

从 [nodejs.org](https://nodejs.org/en/download/) 下载 macOS 官方预编译二进制包，需要同时支持 arm64（Apple Silicon）和 x86_64（Intel）。

推荐使用 `node-pkg` 格式（tar.gz）而非安装包：

```bash
# 创建临时工作目录
mkdir -p /tmp/omnia-packaging/node-bin

# 下载 Node.js LTS（arm64）
curl -L https://nodejs.org/dist/v22.16.0/node-v22.16.0-darwin-arm64.tar.gz \
  -o /tmp/node-arm64.tar.gz

# 下载 Node.js LTS（x86_64）
curl -L https://nodejs.org/dist/v22.16.0/node-v22.16.0-darwin-x64.tar.gz \
  -o /tmp/node-x64.tar.gz

# 解压并提取 node 二进制
tar xzf /tmp/node-arm64.tar.gz -C /tmp/ --strip-components=1
cp /tmp/bin/node /tmp/omnia-packaging/node-bin/node-arm64

tar xzf /tmp/node-x64.tar.gz -C /tmp/ --strip-components=1
cp /tmp/bin/node /tmp/omnia-packaging/node-bin/node-x64

# 用 lipo 合并为通用二进制
lipo -create \
  /tmp/omnia-packaging/node-bin/node-arm64 \
  /tmp/omnia-packaging/node-bin/node-x64 \
  -output /tmp/omnia-packaging/node-universal

echo "Node universal binary size:"
ls -lh /tmp/omnia-packaging/node-universal
```

> Node.js 通用二进制约 100–150 MB，会增大 DMG 体积。若只面向 Apple Silicon 用户，可仅保留 arm64 版本。

### 2b. 准备 NeteaseCloudMusicApi npm 包

```bash
# 创建 NeteaseCloudMusicApi 打包目录
mkdir -p /tmp/omnia-packaging/NeteaseCloudMusicApi

# 进入目录，安装包（离线打包，不依赖用户网络）
cd /tmp/omnia-packaging/NeteaseCloudMusicApi

# 初始化 package.json
cat > package.json << 'EOF'
{
  "name": "omnia-netease-api",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "NeteaseCloudMusicApi": "latest"
  }
}
EOF

# 安装依赖（会创建 node_modules）
npm install --omit=dev

# 查找入口文件（通常是 app.js 或 server.js）
ls node_modules/NeteaseCloudMusicApi/
```

找到入口文件后，创建一个启动脚本：

```bash
cat > start.js << 'EOF'
// OmniaPlayer 启动脚本 - 以静默模式启动 NeteaseCloudMusicApi
process.env.PORT = process.env.NETEASE_PORT || '3000';
process.env.HOST = '127.0.0.1';

// 抑制启动时的 console 输出，避免干扰 app log
const originalLog = console.log;
console.log = (...args) => {
  // 仅输出错误信息
};

require('./node_modules/NeteaseCloudMusicApi/app');
EOF
```

验证可以启动：

```bash
/tmp/omnia-packaging/node-universal start.js &
sleep 2
curl -s http://127.0.0.1:3000/search?keywords=test&limit=1 | head -c 200
# 应返回 JSON，包含 "result" 字段
kill %1
```

### 2c. 修改 NeteaseClient.swift 以使用 bundled runtime

当前 `NeteaseClient.swift` 通过 `npx -y NeteaseCloudMusicApi` 启动代理，打包后需要改为使用 Bundle 内的 node 和 API 文件。

找到 `startProxyIfPossible()` 方法，添加对 bundled runtime 的支持：

```swift
// Omnia/Platforms/Netease/NeteaseClient.swift

private func startProxyIfPossible() async throws {
    // 优先使用 Bundle 内的 node + NeteaseCloudMusicApi
    let bundleNode = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/node")
    let bundledApi = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/NeteaseCloudMusicApi/start.js")

    let nodeExecutable: String
    let apiScript: String

    if FileManager.default.fileExists(atPath: bundleNode.path) &&
       FileManager.default.fileExists(atPath: bundledApi.path) {
        // 正式打包模式：使用 Bundle 内的 node
        nodeExecutable = bundleNode.path
        apiScript = bundledApi.path
    } else {
        // 开发模式：回退到系统 npx
        guard let npx = ExecutableResolver.findExecutable(named: "npx") else {
            throw NeteaseClientError.proxyUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "NeteaseCloudMusicApi"]
        try process.run()
        return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodeExecutable)
    process.arguments = [apiScript]
    // 设置工作目录为 NeteaseCloudMusicApi 目录
    process.currentDirectoryURL = bundledApi.deletingLastPathComponent()
    try process.run()
}
```

---

## 第三步：构建 Release 版本

使用 Xcode Archive 方式构建（推荐），确保正确生成 `.app` Bundle：

```bash
cd /Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/OmniaPlayer-swift

# 替换为你的实际 Team ID 和证书名
TEAM_ID="YOUR10CHARTEAMID"
SIGN_IDENTITY="Developer ID Application: Your Name (${TEAM_ID})"

xcodebuild archive \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme Omnia \
  -configuration Release \
  -archivePath build/Omnia.xcarchive \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | tee build/xcodebuild-archive.log
```

Archive 成功后，验证 `.app` 已生成：

```bash
ls build/Omnia.xcarchive/Products/Applications/
# 应显示 Omnia.app
```

导出为独立 `.app`：

```bash
# 创建 ExportOptions.plist
cat > build/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR10CHARTEAMID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/Omnia.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist
```

导出目录：`build/export/Omnia.app`

---

## 第四步：嵌入运行时依赖

### 4a. 嵌入 VLCKit.framework

VLCKit 已在 Xcode Archive 步骤自动嵌入到 `Contents/Frameworks/`，验证一下：

```bash
ls build/export/Omnia.app/Contents/Frameworks/
# 应包含 VLCKit.framework
```

如果不存在，手动复制：

```bash
# 从 xcframework 中提取通用架构 slice
cp -R Vendor/VLCKit/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework \
  build/export/Omnia.app/Contents/Frameworks/
```

### 4b. 嵌入 Node.js binary

```bash
cp /tmp/omnia-packaging/node-universal \
  build/export/Omnia.app/Contents/MacOS/node

chmod +x build/export/Omnia.app/Contents/MacOS/node
```

### 4c. 嵌入 NeteaseCloudMusicApi

```bash
mkdir -p build/export/Omnia.app/Contents/Resources/NeteaseCloudMusicApi

cp -R /tmp/omnia-packaging/NeteaseCloudMusicApi/. \
  build/export/Omnia.app/Contents/Resources/NeteaseCloudMusicApi/
```

验证结构：

```bash
ls build/export/Omnia.app/Contents/Resources/NeteaseCloudMusicApi/
# 应显示: package.json  start.js  node_modules/
```

---

## 第五步：代码签名

所有可执行文件和 Framework 必须在公证前完成签名，顺序为**从内到外**。

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (YOUR10CHARTEAMID)"
APP_PATH="build/export/Omnia.app"

# 1. 签名 VLCKit.framework 内部的所有二进制
find "${APP_PATH}/Contents/Frameworks/VLCKit.framework" \
  -type f \( -name "*.dylib" -o -perm +111 \) | while read f; do
    codesign --force --sign "${SIGN_IDENTITY}" \
      --timestamp --options runtime "${f}"
done

# 签名整个 VLCKit.framework
codesign --force --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  "${APP_PATH}/Contents/Frameworks/VLCKit.framework"

# 2. 签名其他 Frameworks（GRDB、KeychainAccess 等）
find "${APP_PATH}/Contents/Frameworks" \
  -name "*.framework" \
  ! -name "VLCKit.framework" | while read fw; do
    codesign --force --sign "${SIGN_IDENTITY}" \
      --timestamp --options runtime "${fw}"
done

# 3. 签名 node 二进制
codesign --force --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  "${APP_PATH}/Contents/MacOS/node"

# 4. 签名主可执行文件
codesign --force --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  "${APP_PATH}/Contents/MacOS/Omnia"

# 5. 签名整个 .app Bundle（最后一步）
codesign --force --deep --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  --entitlements Omnia/Omnia-entitlement.plist \
  "${APP_PATH}"

# 验证签名
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}"
```

> `--options runtime` 开启 Hardened Runtime，是公证的必要条件。

---

## 第六步：公证（Notarization）

Apple 公证是分发 Developer ID 签名 app 的必要步骤（macOS Gatekeeper 要求）。

### 6a. 创建 App-Specific Password

前往 [appleid.apple.com](https://appleid.apple.com) → 安全 → App 专用密码，生成一个并记录。

### 6b. 存储凭据到 Keychain（只需一次）

```bash
xcrun notarytool store-credentials "OmniaPlayer-Notarization" \
  --apple-id "your@apple.id" \
  --team-id "YOUR10CHARTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### 6c. 打包并提交公证

```bash
# 创建用于公证的 ZIP（公证服务接受 ZIP 或 DMG）
ditto -c -k --keepParent \
  build/export/Omnia.app \
  build/Omnia-notarize.zip

# 提交公证（异步，通常需要 5–15 分钟）
xcrun notarytool submit build/Omnia-notarize.zip \
  --keychain-profile "OmniaPlayer-Notarization" \
  --wait \
  | tee build/notarization.log
```

查看最终状态，应显示 `status: Accepted`。

### 6d. Staple 公证票据

```bash
xcrun stapler staple build/export/Omnia.app

# 验证 staple
xcrun stapler validate build/export/Omnia.app
spctl --assess --type execute --verbose=2 build/export/Omnia.app
```

---

## 第七步：制作 DMG

### 7a. 准备 DMG 背景图（可选）

准备一张 `1600×1000` px 的背景图，放在 `docs/dmg-background.png`。

### 7b. 创建 DMG

```bash
VERSION="1.0.0"  # 与 CFBundleShortVersionString 保持一致

create-dmg \
  --volname "Omnia ${VERSION}" \
  --volicon "Omnia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512x512@2x.png" \
  --window-pos 200 120 \
  --window-size 800 500 \
  --icon-size 100 \
  --icon "Omnia.app" 200 200 \
  --hide-extension "Omnia.app" \
  --app-drop-link 600 200 \
  "build/Omnia-${VERSION}.dmg" \
  "build/export/"
```

> 如果有自定义背景，追加参数：
> ```bash
> --background "docs/dmg-background.png" \
> ```

### 7c. 公证 DMG（推荐）

```bash
xcrun notarytool submit "build/Omnia-${VERSION}.dmg" \
  --keychain-profile "OmniaPlayer-Notarization" \
  --wait

xcrun stapler staple "build/Omnia-${VERSION}.dmg"
```

---

## 第八步：回归验证

在一台**没有安装 Node.js、没有安装 VLC 的干净 Mac** 上测试（或用独立用户账号）：

### 安装验证
- [ ] 从 DMG 拖入 Applications，macOS Gatekeeper 不弹出 "无法验证开发者" 警告
- [ ] 双击启动，Omnia 正常出现在 Dock

### NeteaseCloudMusicApi 验证
- [ ] 启动后 `lsof -i :3000` 显示有进程在监听
- [ ] 搜索网易云歌曲，日志出现 `stream URL via local proxy` 而非 `stream URL via direct /api`
- [ ] 网易云歌曲播放正常，无 `403 Forbidden` 错误

### VLCKit 验证
- [ ] 播放日志出现 `VLCBackend` 相关输出
- [ ] 切歌无延迟，播放不卡顿

### 退出验证
- [ ] 退出 Omnia 后，`lsof -i :3000` 不再显示监听进程（避免后台 node 进程残留）

---

## 第九步：发布到 GitHub Releases

```bash
VERSION="1.0.0"

# 创建 git tag
git tag -s "v${VERSION}" -m "Release v${VERSION}"
git push origin "v${VERSION}"

# 创建 GitHub Release 并上传 DMG
gh release create "v${VERSION}" \
  "build/Omnia-${VERSION}.dmg" \
  --title "Omnia v${VERSION}" \
  --notes "## 更新内容

- TODO: 填写本次版本变更内容

## 安装方式

1. 下载 \`Omnia-${VERSION}.dmg\`
2. 双击挂载，将 Omnia.app 拖入 Applications 文件夹
3. 首次启动右键选择「打开」

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Apple Silicon 或 Intel Mac"
```

---

## 快速参考脚本

将上述步骤整合为一个脚本 `scripts/build-dmg.sh`（手动执行，非自动化 CI）：

```bash
#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: $0 <version> (e.g. 1.0.1)}"
TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID env var}"
SIGN_IDENTITY="Developer ID Application: $(security find-identity -v -p codesigning | grep "${TEAM_ID}" | grep -o '"Developer ID Application:[^"]*"' | tr -d '"' | head -1)"

echo "==> Building Omnia v${VERSION}"

# Step 1: Archive
xcodebuild archive \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme Omnia \
  -configuration Release \
  -archivePath build/Omnia.xcarchive \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

# Step 2: Export
xcodebuild -exportArchive \
  -archivePath build/Omnia.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist

# Step 3: Embed runtimes
cp /tmp/omnia-packaging/node-universal build/export/Omnia.app/Contents/MacOS/node
chmod +x build/export/Omnia.app/Contents/MacOS/node
cp -R /tmp/omnia-packaging/NeteaseCloudMusicApi/. \
  build/export/Omnia.app/Contents/Resources/NeteaseCloudMusicApi/

# Step 4: Re-sign after adding binaries
codesign --force --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  build/export/Omnia.app/Contents/MacOS/node

codesign --force --deep --sign "${SIGN_IDENTITY}" \
  --timestamp --options runtime \
  build/export/Omnia.app

# Step 5: Notarize app
ditto -c -k --keepParent build/export/Omnia.app build/Omnia-notarize.zip
xcrun notarytool submit build/Omnia-notarize.zip \
  --keychain-profile "OmniaPlayer-Notarization" \
  --wait
xcrun stapler staple build/export/Omnia.app

# Step 6: Create DMG
create-dmg \
  --volname "Omnia ${VERSION}" \
  --window-pos 200 120 \
  --window-size 800 500 \
  --icon-size 100 \
  --icon "Omnia.app" 200 200 \
  --hide-extension "Omnia.app" \
  --app-drop-link 600 200 \
  "build/Omnia-${VERSION}.dmg" \
  "build/export/"

# Step 7: Notarize DMG
xcrun notarytool submit "build/Omnia-${VERSION}.dmg" \
  --keychain-profile "OmniaPlayer-Notarization" \
  --wait
xcrun stapler staple "build/Omnia-${VERSION}.dmg"

echo "==> Done: build/Omnia-${VERSION}.dmg"
```

---

## 常见问题

### Q: `xcodebuild archive` 找不到 scheme

```bash
xcodebuild -list -workspace .swiftpm/xcode/package.xcworkspace
```

确认 scheme 名称，SPM 自动生成的 scheme 可能带有后缀。

### Q: 公证被拒（notarization rejected）

查看详细错误：

```bash
xcrun notarytool log <submission-id> --keychain-profile "OmniaPlayer-Notarization"
```

常见原因：
- 未启用 Hardened Runtime（`--options runtime` 缺失）
- 内嵌的 Node.js binary 未签名
- 签名时间戳缺失（`--timestamp` 缺失）

### Q: NeteaseCloudMusicApi 启动后 3000 端口无响应

1. 检查 node binary 权限：`ls -la Omnia.app/Contents/MacOS/node`
2. 手动测试：`Omnia.app/Contents/MacOS/node Omnia.app/Contents/Resources/NeteaseCloudMusicApi/start.js`
3. 检查 node_modules 是否完整：`ls Omnia.app/Contents/Resources/NeteaseCloudMusicApi/node_modules/NeteaseCloudMusicApi/`

### Q: VLCKit.framework 未被自动嵌入

在 Package.swift 的 `executableTarget` 中确认 VLCKit 在 dependencies 列表内，且 `.binaryTarget` 指向正确路径。Xcode Archive 应自动处理嵌入，若没有，手动复制后重新签名。

### Q: Gatekeeper 仍然阻止运行（即使已公证）

```bash
xattr -cr /Applications/Omnia.app
```

清除隔离属性后再尝试打开（通常只在从非 DMG 途径安装时出现）。
