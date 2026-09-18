---
type: memory
title: 2026-09-18 Mac Developer ID 签名+公证打通(绕过 cloud signing)
created: 2026-09-18T10:10:36.859032+00:00
tags:
  - remotecrab
  - mac
  - notarization
  - developer-id
  - release
---

# 2026-09-18 Mac Developer ID 签名+公证打通(绕过 cloud signing)

# 2026-09-18 RemoteCrab Mac 公证分发

## 结论
Mac 端 Developer ID 签名 + 公证**已跑通**(app 单独公证 Accepted),唯一剩余阻塞是内嵌麦克风 pkg 的 Developer ID Installer 签名卡在钥匙串密码提示。

## 关键发现
1. **xcodebuild -exportArchive 走不通**:报 `Cloud signing permission error` — 当前 ASC API key 没有 "cloud-managed distribution certificates" 权限(需要 Account Holder/Admin 授予,或换 Admin 的 key)。archive 本身(automatic dev signing)是好的。
2. **绕过方案(已验证)**:archive(automatic/Apple Development)→ 手工把 archive 里的 .app 用 `codesign --options runtime --timestamp --sign "Developer ID Application"` 逐层重签(system extension → appex → app)→ 删掉 `Contents/embedded.provisionprofile`(Developer ID app 不能带开发 profile)→ notarize。**结果 Accepted,并且不需要任何 Developer ID provisioning profile** —— sysex 的 `com.apple.developer.system-extension.install` 和 app groups 结 entitlements 在 Developer ID 下没被要求 profile 背书(实测)。嵌套: `Contents/Library/SystemExtensions/*.systemextension` + `Contents/PlugIns/*.appex`。
3. **内嵌 pkg 是公证唯一失败点**:notary 报 (a) `RemoteCrabMicrophone.driver` 的签名没有 secure timestamp,(b) pkg 本身未签名。修法:driver 用 Developer ID Application + `--timestamp` 签(已在 `scripts/build-mic-driver-pkg.sh` 的 xcodebuild 加 `OTHER_CODE_SIGN_FLAGS="--timestamp"`),再用 `productsign --sign "Developer ID Installer: ..."` 签 pkg,notarize + staple。
4. **productsign 卡住**:首次 productsign 会弹 GUI 钥匙串密码框(密钥名 "diiformac",即 Developer ID Installer 私钥),需要用户输入登录密码并点 "Always Allow"(一次即可)。codesign 用 Developer ID Application 不弹,因为那条 key 的 ACL 之前已授权。
5. **证书都在**:`Developer ID Application` 和 `Developer ID Installer`(Beijing VGO Co;Ltd / 5XNDF727Y6);公证凭证在 `~/.config/mddock/production.env`(APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID)。Apple timestamp server 可达(不是它的问题)。
6. **脚本**:`scripts/release-mac.sh <ver>`(build→sign→notarize→staple→DMG;`--skip-pkg` 可跳过)。`ExportOptions-developerid.plist` 备着但当前用不上。

## 还未验证
- 装到干净 Mac 上(或本机删掉现有 sysex 后)确认 Developer ID 签名 + 无 profile 时,OSSystemExtensionRequest 仍能安装并让用户在系统设置批准。
- 归档用的是 arm64(未做 universal);部署目标 macOS 26.0 偏新,朋友机器版本需要注意。
