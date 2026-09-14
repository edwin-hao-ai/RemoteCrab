# RemoteCrab 发布流程

_2026-09-13_

## A. iOS（上 App Store 的只有这一个）
`scripts/release-ios.sh` 负责：升版本 → xcodegen → 签名 Release 归档 → 导出 IPA →
（可选）上传元数据/截图 → `altool` 上传。

**已验证可用（本地半程，无需 ASC 凭证）**：
```sh
xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/RemoteCrabCapture.xcarchive archive \
  DEVELOPMENT_TEAM=5XNDF727Y6 -allowProvisioningUpdates      # ✅ ARCHIVE SUCCEEDED

xcodebuild -exportArchive -archivePath build/RemoteCrabCapture.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates                                   # ✅ 导出 build/export/RemoteCrabCapture.ipa
```
> `method: debugging` 用于本机测试；正式上传把 `ExportOptions.plist` 的 `method` 改成
> `app-store-connect`（或 `release-testing` 做 TestFlight）。

**上传前需要你准备**（我无法代做）：
1. Apple Developer Program（$99/年）。
2. App Store Connect 建 app 记录，bundle id = `com.ibridge.iBridgeCapture`，
   把真实 `appId` 填进 `scripts/ios-metadata.json`。
3. 生成 App Store Connect API Key，写 `~/.config/remotecrab/ios-release.env`（0600）：
   ```
   APPLE_API_KEY=XXXXXXXXXX
   APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   APPLE_API_KEY_PATH=$HOME/.config/remotecrab/AuthKey_XXXXXXXXXX.p8
   APPLE_TEAM_ID=5XNDF727Y6
   ```
4. 真机截图（现只有 mockup）、隐私政策/支持 URL 托管。

然后：
```sh
./scripts/release-ios.sh 0.2.0 --all --create-version
```

> 审核注意：见 `docs/RELEASE_READINESS.md` §4 —— 配套 Mac App 审核员装不了，
> 演示模式（设置里开）是给他们体验用；营销别写"Zoom 当选摄像头"直到 F1 验证。

## B. Mac（不走 Mac App Store，单独分发）
Mac 端要 Accessibility + CMIO system extension，**不进 MAS**。发布 = 签名 + 公证 + 分发：
```sh
# 1. Release 构建（Developer ID 签名）
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
  -configuration Release -destination 'platform=macOS' archive \
  CODE_SIGN_IDENTITY="Developer ID Application" -allowProvisioningUpdates
# 2. 导出 .app，打成 dmg/zip，公证
xcrun notarytool submit RemoteCrabReceiver.dmg --keychain-profile <profile> --wait
xcrun stapler staple RemoteCrabReceiver.dmg
```
- 虚拟麦克风 pkg：`scripts/build-mic-driver-pkg.sh` → `dist/RemoteCrabMicrophone.pkg`；
  用 **Developer ID Installer** 证书 `productsign` + 公证，再嵌进 App；
  设置页「麦克风驱动」一键打开它。

## C. 本机验证
```sh
xcrun devicectl device install app --device <udid> build/export/RemoteCrabCapture.ipa   # 或 .app
```
