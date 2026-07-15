# 11 — 打通本机按住说话 tracer

**What to build:** 在不依赖付费模型凭证的情况下，打通真实全局按键、录音、松开时输入目标捕获、确定性本地测试转录、保守文本送达或待复制结果、取消和基础会话记录的完整路径。

**Blocked by:** 10 — 建立可运行的菜单栏基础

**Status:** ready-for-agent

- [ ] `VoiceInputSessions` 只通过语义命令和 revisioned presentation 暴露行为，并保证同一时间最多一个活动会话
- [ ] 默认 `Fn` 能产生按下/松开边沿；自定义组合键能注册 pressed/released 并拒绝冲突
- [ ] 按住录制 16 kHz/16-bit/mono WAV，松开停止；`Esc`、静音、短录音和 60 秒 watchdog 行为符合规格
- [ ] 松开后第一次 AX 查询捕获输入目标，模型等待期间切换窗口不改变快照
- [ ] 本地确定性转录 adapter 能把完整流程送达到已验证目标，无法确认时产生待复制结果且不自动改剪贴板
- [ ] 安全输入、权限缺失、目标失效、并发变化、重复事件和迟到结果均 fail closed
- [ ] 每条红绿循环通过 `VoiceInputSessions` seam 验证外部行为，完整测试通过

