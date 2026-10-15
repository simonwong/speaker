## 变更说明

<!-- 这个 PR 做了什么，为什么需要。关联 issue 请写 Closes #<n>。 -->

## 检查清单

- [ ] 按 [`docs/agents/development.md`](../docs/agents/development.md) 跑过改动路径对应的本地检查（UI 规格由 CI 运行，大改 UI 设计时才本机跑 `./scripts/test --ui-only`）
- [ ] 已按 [AGENTS.md](../AGENTS.md) 的「Read by task」阅读并遵循对应文档：
      改动模块或接口读 [`docs/architecture.md`](../docs/architecture.md)；
      改动用户可见的语音输入行为读 [`docs/specs/voice-input.md`](../docs/specs/voice-input.md)；
      改动构建、测试或发布入口读 [`docs/agents/development.md`](../docs/agents/development.md)；
      改动更新通道或发布流程读 [`docs/releasing.md`](../docs/releasing.md)；
      新增或调整领域术语读 [`docs/agents/domain.md`](../docs/agents/domain.md)
- [ ] 改动的 shell 脚本已通过 `zsh -n`
- [ ] 描述、截图与日志中不包含转录文字、音频、API Key 或 provider 返回的原始消息
