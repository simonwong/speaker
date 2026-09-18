# ADR-0009: Select a text-only Refinement Provider per session

Status: Accepted

Date: 2026-09-18

This supersedes ADR-0003's single text-provider restriction. Doubao remains the only audio provider; Default Smoothing ends with its confirmed Stage Result. Other Refinement Modes send only that text, the instruction, and the press-time Personal Dictionary Entry words to the explicitly selected Refinement Provider. DeepSeek, OpenAI, Kimi, and GLM have built-in catalogs; Custom accepts an HTTPS base URL and model ID. There is no automatic provider or region fallback.

The session snapshot freezes provider, model, endpoint, and credential namespace alongside the Refinement Mode. Credentials stay outside the snapshot and are read from the matching account when needed. Built-in endpoints are fixed. A Custom credential is bound to its normalized base URL; changing the destination requires an explicit Key save, and redirects are refused. Provider selection and mode activation change atomically so a recording cannot capture a partly changed configuration.

A small catalog follows pi's provider/model separation without importing its agent runtime. Catalog models use documented non-thinking request profiles; manually entered IDs use the selected provider's profile and are not a compatibility guarantee. The shared text adapter requires non-streaming JSON, normal completion, no refusal or tool call, and exactly one non-empty text field. Encoded requests are capped at 256 KiB and responses at 1 MiB before decoding. Explicit failures preserve the Doubao Stage Result; User Cancellation discards late results. No repair requests or silent parameter retries are sent.

Existing settings retain DeepSeek and its previous model. Keys are independent, and removing the selected Key disables refinement without deleting other providers' credentials. Session Records retain provider/model attribution; older records retain their DeepSeek interpretation. The legacy `deepSeekText`, `deepSeekRequestID`, and `deepseek` timing keys remain on disk for compatibility. Copied diagnostics exclude custom endpoints and manually entered model IDs. Offline protocol checks do not establish live model availability or semantic quality.
