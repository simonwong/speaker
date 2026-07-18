# Speaker Documentation

This directory contains durable product, architecture, decision, research, and delivery documentation. Temporary exploration and completed implementation tickets do not belong here.

## Product contract

- [Voice input specification](specs/voice-input.md) defines the user-visible behavior, implementation decisions, test seams, and scope.
- [Compatibility matrix](compatibility.md) defines the automated and real-machine evidence required for safe cross-application delivery.
- [Production readiness](production-readiness.md) tracks the remaining release gates.

## Architecture and decisions

- [Architecture](architecture.md) explains the current module shape, interfaces, seams, adapters, and invariants.
- [Architecture decision records](adr/README.md) preserve decisions that future architecture work should not silently re-litigate.

## Research

- [macOS input and delivery](research/macos-input-and-delivery.md) records the platform limits behind shortcut capture and conservative delivery.
- [Doubao streaming ASR](research/doubao-streaming-asr.md) records the credential, resource, and WebSocket contract used by Speaker.
- [DeepSeek text refinement](research/deepseek-text-refinement.md) records the optional refinement contract and fallback rules.
- [Secure updates](research/secure-update-mechanism.md) records the production update design.

Research pages are dated evidence, not timeless provider contracts. Recheck their primary sources before changing provider or platform adapters.

## Operations and agent guidance

- [Release process](releasing.md) defines development installation and production distribution.
- [`agents/`](agents/) contains repository workflow guidance for agents.
