# 14 — 交付可选 DeepSeek 整理模式

**What to build:** 用户可以选择精简清理、完整重写或自定义整理模式；这些模式在豆包成功后调用 DeepSeek，严格校验结果，任何失败都使用豆包文本完成本次输入。

**Blocked by:** 12 — 交付豆包默认顺滑听写

**Status:** ready-for-agent

- [ ] DeepSeek Key 只存入 Keychain，未配置时依赖它的整理模式不可启用
- [ ] 提供默认顺滑、精简清理、完整重写和可命名的自定义模式，空或超长自定义提示词不可启用
- [ ] 请求使用当前 V4 Flash、关闭思考、非流式 JSON Output、固定不变量、20 秒总预算和有界输出
- [ ] 只有正常 stop、精确单字段非空 JSON 和本地边界校验全部通过时采用 DeepSeek 文本
- [ ] 鉴权、余额、限流、网络、超时、取消、截断、过滤、空 JSON、解析和异常膨胀均记录阶段状态并无损回退豆包
- [ ] 默认顺滑仍不调用 DeepSeek；所有模式与回退通过 `VoiceInputSessions` 与 HTTP adapter seam 测试

