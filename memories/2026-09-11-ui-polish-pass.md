# iBridge UI 审计 +  polish 全量扫荡（2026-09-11 下午）

## 做了什么

用户要求扫全部 UI（iOS + Mac）找问题。两个 explore 子代理并行审计（以 iBridgeCore
DesignSystem token 为基准），产出 ~80 条发现，分四级修复，每级 `./scripts/test.sh`
gate 后单独提交：

1. `59df597` Mac 阻断级
2. `c3adab6` iOS 状态语义/触控目标/边缘手势
3. `8b11eaa` + `95e4463` 一致性归并（iOS + Mac）
4. `1b7b6ad` 扫尾 + `8ab9a59` AGENTS.md 同步

## 重要发现（审计比预想值钱）

- **Mac 的 inputInjector 一直是 RecordingInputInjector 测试 mock**——触控板/键盘
  事件在 Mac 上被静默丢弃。UI 审计顺手抓出了功能级 bug。教训：UI 走查也会暴露
  接线问题，"看起来能用"和"接了真实现"是两回事。
- 菜单栏 ActionRow 全是死的（不是 Button、无 openWindow、快捷键未注册）；控制
  面板的 Preview 按钮 action 是把自己切全屏。LSUIElement app 开窗口必须配
  `NSApp.activate()`，否则窗口藏在别的 app 后面。
- 延迟 sparkline 曾是正弦波假数据（并行会话后来接了真 RTT）；6 个偏好设置全部
  是只写不读的假开关。

## 经验

- **设计系统只建不用 = 没有设计系统**。本次大量问题是"token 存在但没人用"：
  IBLocale.Error 整套零调用、IBModifierBar/IBKeyboardKey 被绕开重造、四个屏四种
  手写渐变。审计方法：先读 DesignSystem 建立基准，再逐文件比对。
- IBStatusPill 这类核心组件要覆盖全部状态（本次补了 .idle/.searching/.connecting），
  否则调用方各自手搓，三套词汇并存。
- IBStatusPill 硬编码 `.white` 前景在 Mac 菜单弹窗（跟随系统外观）浅色模式下对比度
  不足——跨平台共享组件要考虑 appearance 适配（本次加 foreground 参数，弹窗传
  `.primary`）。
- 并行会话活跃时：子代理只改文件不提交，父代理逐个 stage 自己碰过的文件提交；
  AGENTS.md 会被并行会话更新，修复前先核对发现是否已被修掉（本次确实有几条已修）。
