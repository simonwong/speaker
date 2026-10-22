# ADR-0002: Freeze the Input Target When Recording Ends

Status: Accepted

Date: 2026-07-18

Last updated: 2026-10-22

## Context

Provider processing can finish after the user changes applications, windows, selections, or text. macOS has no universal atomic operation that inserts text into an arbitrary historical editing position. Accessibility implementations also vary across native, web, Electron, rich-text, terminal, and secure controls.

Retargeting to the current focus would be convenient but could place speech into the wrong document. Optimistically reporting an unconfirmed mutation would make manual recovery unsafe because the user could duplicate text.

## Decision

The editable position focused when recording ends becomes the Voice Input Session's only Input Target.

The physical release callback freezes only the frontmost process, without target-application AX IPC. Immediately after the callback returns, Speaker reads that exact process's current focused Accessibility element, or its focused window when no element is exposed, and creates the immutable Input Target token. Delivery consumes that token and revalidates security class, focus, process identity, and any available value or selection evidence before mutation.

Speaker does not use an `AXObserver` focus cache as an authoritative release-time identity source. Real same-process, multi-window Terminal use showed that focused-window notifications can be delayed or absent: a stale cached element caused the first session to work and later sessions to fail even though the new window was focused. An App activation observer cannot repair this because switching windows does not activate a different process. The small interval between the physical release and the asynchronous AX read is an explicit tradeoff; the release-time PID fence prevents the read from following focus into another process, and later exact-target validation prevents delivery after the captured input changes.

All editable targets use one delivery algorithm after a shared commit gate succeeds. Accessibility supplies transient identity and security evidence only; it never mutates target text. Speaker preflights event-post access, snapshots the pasteboard, writes the transcript with a private ownership marker, then posts one physical Command-V sequence from the combined login-session event state. It restores the snapshot only if the change count and marker still prove ownership. Once the paste command is posted it is committed, is never repeated, and is never exposed as retryable Pending Copy merely because a target receipt is unavailable.

The restore waits for evidence that the paste was consumed rather than a fixed delay. A target with readable value evidence releases the clipboard when its receipt confirms the expected value. Otherwise the transcript is written as promised clipboard data, its first read marks consumption, and the restore runs shortly after that read but no sooner than a short floor after Command-V. A three-second cap restores the clipboard regardless. A target that ends its receipt window showing a third value, neither the original nor the expected one, is not pasted again; its result becomes Pending Copy with the `deliveryUnconfirmed` reason so the user checks the target before copying.

Secure, missing, changed, closed, or unverifiable targets produce a Pending Copy Result only while no paste event has been posted. A posted command is recorded separately from a target-confirmed insertion. Speaker never restores focus, replaces an entire rich-document value, or overwrites a newer user clipboard value.

## Consequences

- Switching windows after release never retargets a result.
- Switching windows inside one application before release does not depend on an observer notification.
- A different field focused after post-callback capture invalidates the original target.
- Automatic delivery may change the general pasteboard for up to three seconds; the original contents are conditionally restored once the paste is consumed or the cap passes.
- A clipboard manager that ignores the Transient marker and reads the promised text first can mark the paste consumed early; the receipt and the restore floor bound that case.
- Conservative fallback is normal product behavior, not an exceptional generic error.
- Compatibility claims are evidence-based per target family; there is no universal delivery promise.
- Application identity may be used as transient diagnostics but is not displayed, searched, or persisted in Session Records and never selects a delivery mechanism.
- Tests cross the target-capture and delivery interfaces with live and deterministic adapters at the same seams.
