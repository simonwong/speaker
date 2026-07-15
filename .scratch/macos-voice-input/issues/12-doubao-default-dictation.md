# 12 — 交付豆包默认顺滑听写

**What to build:** 用户配置自己的豆包 Key 后，按住说话、松开提交到豆包大模型录音文件极速版，使用语义顺滑结果自动送达或进入待复制结果，并留下可诊断的阶段记录。

**Blocked by:** 11 — 打通本机按住说话 tracer

**Status:** done

- [x] 豆包 Key 只存入 Keychain，设置页可保存、删除并执行不泄露凭证的连接检查
- [x] 请求使用指定 flash 端点、资源标识、请求 UUID、Base64 WAV、标点、ITN 与语义顺滑参数
- [x] 成功响应提取文本和请求标识；静音、鉴权、未开通、限流、服务和网络错误映射为稳定用户状态
- [x] 默认顺滑路径绝不调用 DeepSeek
- [x] 取消和迟到响应不会写入输入目标；临时音频在所有终态删除
- [x] 豆包 HTTP adapter 契约和完整听写路径均通过公开 seam 测试

自动证据：`./scripts/test` 在获准访问登录 Keychain 的环境中通过 20 条 core specs，`./scripts/build` 与 App bundle 启动通过。真实豆包账号的连接与延迟校准需要用户自己的 Key，精确保留到 ticket 17，不伪称已完成。
