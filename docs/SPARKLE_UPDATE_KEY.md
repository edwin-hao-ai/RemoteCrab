# Sparkle 更新签名密钥（Mac 自动更新）

_2026-09-27 · Developer-ID Mac App 的 Sparkle appcast 用 EdDSA 私钥签名。
丢了这把私钥，就再也无法签发新的 Mac 更新。本文是它的位置、备份与恢复说明。_

## 是什么

- **算法 / 工具**：Sparkle 2 的 EdDSA（`generate_keys` / `generate_appcast` / `sign_update`）。
- **作用**：Mac 端 `UpdaterController` 拉取 `https://vgoapp.com/downloads/appcast.xml`，
  用内置于 `Info.plist` 的 **公钥** 校验 appcast 里每个更新包的 EdDSA 签名。
  没有这把私钥就无法发布能被现有用户接受的更新。

## 公钥（可公开）

```
SUPublicEDKey = 6007dgFqcTaRt5gMlxnh263ABbequKpT6wXicnFPZZI=
```

写在 `project-mac.yml`（`RemoteCrabReceiver` → `info.properties`）并生成进
`RemoteCrabReceiver/Info.plist`。**改这个值等于换信任根**（见文末"轮换"）。

## 私钥的位置

| 位置 | 说明 |
|---|---|
| **登录钥匙串**（主） | `generate_keys` 写入的 Sparkle item（service `https://sparkle-project.org`）。`make-appcast.sh` / `generate_appcast` 默认从这里取。 |
| **本机文件备份** | `~/.config/remotecrab/sparkle-ed-private-key`（`0600`）。 |
| **服务器备份** | `root@158.247.219.230:/root/.config/remotecrab/sparkle-ed-private-key`（`0600`，不在 web 目录）。 |

> VPS 主机与 SSH 凭据见 AGENTS.md lesson 35（`~/MDDock/certs/mddock-vps-root`）。

### 常用命令

```sh
# Sparkle 工具在 SPM 产物里（先构建一次 Mac target）：
BIN=.build/ci-derived-data/mac/SourcePackages/artifacts/sparkle/Sparkle/bin

# 打印公钥
"$BIN/generate_keys" -p

# 首次生成密钥（一次性；私钥进登录钥匙串）
"$BIN/generate_keys"

# 导出私钥到文件（备份/迁移用）
"$BIN/generate_keys" -x ~/.config/remotecrab/sparkle-ed-private-key

# 从文件导入到本机钥匙串（换机恢复用）
"$BIN/generate_keys" -f ~/.config/remotecrab/sparkle-ed-private-key
```

> `generate_appcast` 首次访问私钥会弹钥匙串授权框（SecurityAgent），点「始终允许」一次即可。
> 用文件备份时可直接 `generate_appcast --ed-key-file <file> …`（CI / 无钥匙串环境）。

## 发布时怎么用

正常发布走 `scripts/release-mac.sh <version>`（它产出 `RemoteCrab-<version>.zip`），
再用 `scripts/make-appcast.sh <version>` 生成 `dist/appcast/appcast.xml`，
把 appcast + zip 传到 `vgoapp.com/downloads/`。见 AGENTS.md lesson 74。

## 恢复（换了机器 / 钥匙串丢了）

1. 从备份文件恢复：`generate_keys -f <备份文件>`（导入登录钥匙串）；
   或无钥匙串时直接用 `generate_appcast --ed-key-file <备份文件>`。
2. 用 `generate_keys -p` 确认打印出的公钥仍是
   `6007dgFqcTaRt5gMlxnh263ABbequKpT6wXicnFPZZI=`。若不是，说明恢复的是另一把钥匙，
   现有用户的更新会因签名不匹配被拒。

## 安全约定

- **私钥永不入库 / 永不进 git**；只在登录钥匙串 + 上述两个 `0600` 备份文件里。
- 备份文件与公钥**不是**同一层：公钥可以随便放，私钥泄露等于任何人都能伪造你的更新。
- 这把钥匙只管 **macOS** 的 appcast。未来的 Windows / Linux 接收端不用 Sparkle，
  各有各的更新/打包机制——**不要把 Sparkle 私钥发给非 macOS 的构建链**。

## 轮换（如果私钥泄露）

EdDSA 公钥内置在已发布 App 里，无法"直接换"。可行路径：用**旧私钥**签一个
"内含新公钥"的新版本发出去，用户更新到该版本后即信任新公钥，之后再用新钥匙签。
代价是所有旧版本用户都必须先装到这个过渡版本。非必要不要轮换。

---

# Developer ID provisioning profile（macOS 26 起必需）

`com.apple.developer.system-extension.install` 是 **profile-backed** 的受限
entitlement。没有匹配的 provisioning profile，amfid 会在启动前杀掉 App
（`taskgated Invalid Signature` / `No matching profile found`）—— **live 1.0
DMG 就是这样打不开的**（见 AGENTS lesson 75）。

- **文件**：`~/.config/remotecrab/RemoteCrab_DeveloperID.provisionprofile`（`0600`）。
- **服务器备份**：`root@158.247.219.230:/root/.config/remotecrab/RemoteCrab_DeveloperID.provisionprofile`（`0600`）。
- **类型**：`MAC_APP_DIRECT`（Developer ID），绑定 bundle id
  `com.remotecrab.RemoteCrabReceiver` + Developer ID Application 证书，
  带 `SYSTEM_EXTENSION_INSTALL` capability。
- **使用**：`scripts/release-mac.sh` 在签名前把它复制成
  `RemoteCrab.app/Contents/embedded.provisionprofile`（**不再删除**）。
  可用 `REMOTECRAB_DEVID_PROFILE` 覆盖路径。

## 重新生成 / 续期（profile 过期或换证书时）

用已有的 ASC API key（见 `scripts/ios-app-store-metadata.py` 的 JWT 逻辑）：
`POST https://api.appstoreconnect.apple.com/v1/profiles`，body
`profileType: MAC_APP_DIRECT`，relationships 指向 bundle id
`AKWJV8N2A6`（`com.remotecrab.RemoteCrabReceiver`）和 Developer ID 证书
（`certificates`）。返回的 `profileContent` 是 base64，解码即得 profile 文件。
（本次就是这样做出来的，profile id `NST69286HW`。）

## 验证

```sh
security cms -D -i ~/.config/remotecrab/RemoteCrab_DeveloperID.provisionprofile \
  | plutil -p - | grep -A6 Entitlements     # 应含 system-extension.install = true
spctl -a -vvv -t exec /Applications/RemoteCrab.app   # accepted / Notarized Developer ID
# 真正启动一次；被 amfid 杀掉时看：log show --predicate 'process == "amfid"' --info
```
