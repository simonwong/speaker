# ADR-0011: Select the Speech Recognition Method without streaming delivery

Status: Accepted

Date: 2026-09-22

This supersedes ADR-0010's complete-audio-only restriction for OpenAI and Qwen. Users may choose streaming or complete-recording recognition independently for each provider. Existing settings retain their original behavior: Doubao streams, while OpenAI and Qwen submit complete recordings. The provider, method, compatible model, region, and credential ownership are frozen together when recording starts. Changing the method reuses the same provider and region's recognition Key and never issues a probe or retries through another method.

Streaming reduces the opportunity for upload and recognition work to accumulate after recording ends, but it sends audio before final local capture validation. Cancellation stops further transmission and discards the result; it cannot recall audio already received by the provider. Complete-recording recognition waits for successful local capture validation before upload. Neither method carries an accuracy ranking: model quality must be compared on the same representative recordings.

OpenAI and Qwen streaming use their dedicated realtime models and WebSocket contracts, with automatic turn detection disabled. Qwen's manual mode confirms recognition after commit; streaming here describes live audio transmission, not a promise of partial captions before release. OpenAI uses the documented high-delay setting to favor additional audio context over immediate partial text. The recording completion gate authorizes the final manual commit only after the complete local capture succeeds. Intermediate transcription events are never delivered or persisted as Stage Results. The session accepts only the confirmed result for its committed audio and still freezes the Input Target when recording ends. A streaming response from a complete-file HTTP request would not satisfy this method because it would not send audio while recording.

Audio stays bounded in memory. OpenAI's realtime adapter converts the captured PCM to its required sample rate; Qwen uses the capture format. The application keeps the existing five-minute OpenAI and three-minute Qwen recording bounds for both methods. These are application limits, not claims about realtime service maxima. Credentials, secure-target redaction, Waiting For Result, and text-only refinement preserve their existing boundaries.
