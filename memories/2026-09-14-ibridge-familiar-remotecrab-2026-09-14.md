---
type: memory
title: 产品改名决策:iBridge/Familiar → RemoteCrab (2026-09-14)
created: 2026-09-14T14:26:37.818165+00:00
source: cli
---

# 产品改名决策:iBridge/Familiar → RemoteCrab (2026-09-14)

# 改名决策

## 为什么
"iBridge" 会被苹果完全禁掉(商标冲突),必须改名。
用户决定新名字:**RemoteCrab**。

## Logo 方向
赛博风的螃蟹,沿用现有 logo 的苹果 Liquid Glass 风格
(现有 master: assets/app-icon-liquid.svg,menu bar: assets/menu-bar-icon.svg)。

## 现状
项目处于部分改名状态:Mac App 已叫 Familiar(菜单栏/App 名),
但 bundle id(com.ibridge.*)、Target 名、目录名(iBridgeCapture/
iBridgeReceiver/iBridgeCore/iBridgeMicDriver...)、Bonjour 服务
(_ibridge._tcp)、os_log subsystem(com.ibridge)、驱动 bundle id
(com.ibridge.iBridgeMicrophone)、设备 UID、文档全部还是 iBridge。
改名是新会话的主要任务。

## 改名的硬注意事项
- bundle id 变更 = TCC 授权(辅助功能/麦克风/相机)全部重新授予
- CMIO 系统扩展改名 = 用户需重新在系统设置里批准,且系统按原始路径记录,
  重注册走 version-bump 路径(见 AGENTS.md CMIO 节)
- 驱动 bundle id 变更 = 需要重新安装驱动包
- App Store Connect appId 6811599153 已存在,改名涉及 ASC 元数据
