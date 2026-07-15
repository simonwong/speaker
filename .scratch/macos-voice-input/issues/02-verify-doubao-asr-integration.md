# 验证豆包 ASR 的 MVP 接入契约

Type: research
Status: resolved

## Question

截至 2026-07-15，豆包/火山引擎哪一个公开语音识别 API 最适合“按住说话、松开提交”的短语音 macOS 输入场景？核实鉴权材料、音频格式、流式或非流式选择、语义顺滑、自动标点、context、热词/词表、请求取消、错误码、限额与计费，并给出 Swift 客户端可以实现的最小接口契约。只使用官方一手资料，并区分已确认能力与需要真实账号验证的能力。

## Answer

MVP 采用豆包语音识别大模型「录音文件极速版识别 HTTP」：按住期间本地录制 16 kHz/16-bit/mono PCM WAV，松开后通过单次同步 `POST` 提交，避免首版承担 WebSocket、重连和中间结果状态。新版控制台契约为用户自填 `X-Api-Key`，固定资源 ID `volc.bigasr.auc_turbo`，每请求 UUID；成功读取 `result.text` 并保留 `X-Tt-Logid`。自动标点、ITN、语义顺滑可启用，但任意提示词重写仍交给后续文本模型。

词库优先用 `corpus.context` 请求级热词直传；平台词表作为兼容降级。官方未公开同步极速请求的服务端取消接口，也未在公开页给出可锁死的极速版价格和 QPS，因此提交后的取消只保证客户端停止等待，计费、QPS、热词兼容性和实际延迟必须用目标账号验证。

完整证据、错误映射、Swift 最小接口与验收矩阵见 [豆包 ASR 的 macOS MVP 接入契约](../research/doubao-asr-mvp-contract.md)。提示词与语义顺滑的边界见 [豆包语音识别是否支持提示词驱动的文本整理](../research/doubao-speech-text-processing.md)。
