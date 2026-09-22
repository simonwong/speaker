# ADR-0010: Select a Speech Recognition Provider independently of text refinement

Status: Accepted

The complete-audio-only restriction for OpenAI and Qwen is superseded by [ADR-0011](0011-select-the-speech-recognition-method.md). Provider selection and credential isolation remain accepted.

Date: 2026-09-22

This supersedes ADR-0009's Doubao-only audio restriction. The user selects Doubao, OpenAI, or Alibaba Qwen as the Speech Recognition Provider. The Refinement Provider remains a separate text-only choice. Each Voice Input Session snapshots the recognition provider, model, and region when recording starts; later settings changes apply to the next session. Credentials are resolved from that snapshot's namespace. There is no automatic provider or region fallback.

Doubao retains its streaming WebSocket adapter. OpenAI and Qwen initially use their synchronous complete-audio APIs: capture stays in bounded memory, then a WAV request is submitted only after recording ends and local capture validation succeeds. A per-session completion gate distinguishes validated completion from a stream closed by failure or cancellation. This favors a small, verifiable API contract and complete-utterance evaluation before adding live partial transcription. It does not establish that complete-audio recognition is more accurate. Audio is never written to disk, oversized input fails without truncation, redirects are refused, and cancellation discards late results before refinement or delivery.

Recognition credentials are separate from text-refinement credentials, including when both services are OpenAI. Qwen's Beijing and Singapore destinations have separate credential namespaces. Saving or selecting a configuration never sends a probe. Default Smoothing uses Doubao semantic smoothing when Doubao is selected and returns the other providers' recognition output directly; it never silently adds a refinement request. Non-default modes refine only the confirmed text and preserve that text on explicit refinement failure.

Existing installations default to Doubao. Settings retain each provider's model selection. Session Records attribute recognition to the captured provider and model; legacy field names and missing-field defaults preserve old history. Secure targets remain text-free. Deterministic adapter, session, persistence, and application specifications establish wiring and failure behavior; real account availability and recognition quality require separate approved provider acceptance.
