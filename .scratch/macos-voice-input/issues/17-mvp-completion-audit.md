# 17 — 完成 MVP 全量验收

**What to build:** 对实现就绪规格逐项核对当前代码、测试、构建、运行与本机 smoke 证据，修复所有缺口，形成可从源码运行且没有未解释需求空洞的个人 macOS 语音输入 MVP。

**Blocked by:** 15 — 交付详细会话历史与完整设置; 16 — 加固本机运行与系统兼容性

**Status:** ready-for-agent

- [ ] 规格中的每条用户故事和实现决定都有直接代码、测试或明确人工 smoke 证据
- [ ] 聚焦测试、完整测试、release 构建、App bundle 组装和本地启动全部通过
- [ ] 使用非敏感测试凭证完成豆包与 DeepSeek smoke，或把仅缺真实凭证的校准项精确标记而不伪称已验证
- [ ] 权限、取消、降级、敏感数据排除、历史、词库和 provider 错误路径完成风险导向复测
- [ ] Code-review 的 Standards 与 Spec 两个轴没有未处理的高优先级发现
- [ ] Improve-architecture 选定的高价值 deepening 完成或以有根据的决定反馈回 Grill

