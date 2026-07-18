# ADR-0002: Freeze the Input Target When Recording Ends

Status: Accepted

Date: 2026-07-18

## Context

Provider processing can finish after the user changes applications, windows, selections, or text. macOS has no universal atomic operation that inserts text into an arbitrary historical editing position. Accessibility implementations also vary across native, web, Electron, rich-text, terminal, and secure controls.

Retargeting to the current focus would be convenient but could place speech into the wrong document. Optimistically reporting an unconfirmed mutation would make manual recovery unsafe because the user could duplicate text.

## Decision

The editable position focused when recording ends becomes the Voice Input Session's only Input Target.

Speaker freezes the precise focused Accessibility element, process identity, selection, and bounded change evidence. Delivery consumes that same target token and revalidates security class, focus, value, selection, and process identity before mutation.

All delivery adapters mutate only after a shared commit gate succeeds. A committed mutation is settled from its real receipt and is never rewritten as User Cancellation. A mutation without an expected receipt is not reported as delivered.

Secure, missing, unsupported, changed, closed, or unverifiable targets produce a Pending Copy Result. Speaker does not restore focus, simulate paste, or overwrite the clipboard before explicit user action.

## Consequences

- Switching windows after release never retargets a result.
- Even a different field in the same application invalidates the original target.
- Conservative fallback is normal product behavior, not an exceptional generic error.
- Compatibility claims are evidence-based per target family; there is no universal delivery promise.
- Tests cross the target-capture and delivery interfaces with live and deterministic adapters at the same seams.
