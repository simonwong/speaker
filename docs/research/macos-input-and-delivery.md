# macOS Input and Delivery Constraints

Last reviewed: 2026-08-01

This page records the platform evidence behind [ADR-0001](../adr/0001-run-outside-app-sandbox.md) and [ADR-0002](../adr/0002-freeze-the-input-target.md). It is a dated research record; Apple contracts and observed application behavior must be rechecked before widening delivery support.

## Findings

- `Fn` is modifier state rather than a normal character key. A session-level, listen-only `CGEventTap` can observe `flagsChanged` and derive press/release edges from `maskSecondaryFn`.
- A custom modifier-and-key shortcut can use Carbon hot-key registration and receive pressed/released events. The live registration result, not a static conflict list, decides whether the shortcut is available.
- The system-wide Accessibility element exposes the focused application and focused UI element at release. Third-party controls may return unsupported, invalid-element, cannot-complete, or not-implemented errors.
- An `AXUIElement` can be retained in memory, but its validity is not guaranteed after a control, page, window, or process changes. Every later use requires revalidation.
- macOS has no universal atomic operation that inserts text into an arbitrary historical editing position across all applications. Attribute writability, selection behavior, rich-text semantics, and receipt behavior vary by control family.
- Accessibility and Microphone are required. Accessibility covers the cross-application listen/post and AX behavior Speaker needs; Input Monitoring is not added as a duplicate permission.
- Assistive cross-application behavior requires Speaker to run outside App Sandbox.
- Secure Event Input and `AXSecureTextField` targets fail closed. Secure targets never receive automatic text and never persist transcript content.

## Shortcut contract

The event-tap callback performs minimal edge bookkeeping and hands semantic intent to ordered application code. It does not perform AX IPC, stop audio, or start provider work inline. When macOS disables the tap for timeout, Speaker resets gesture ownership, re-enables the tap, and reports recovery.

`Fn` cannot be exclusively registered as an ordinary Carbon hot key. The user's Fn/Globe system setting and external keyboard may produce competing behavior, so Speaker provides a custom-shortcut alternative and requires real-machine evidence.

## Input Target contract

Release snapshots the frontmost process identity without AX IPC. Immediately after the event-tap callback returns, Speaker queries that exact process for its current focused element, falling back to its focused window when necessary. Role, security classification, selection, and bounded change evidence are captured in the resulting one-session token. This design deliberately avoids an authoritative `AXObserver` cache: real same-process Terminal window switching showed that notifications can be delayed or absent, leaving stale focus evidence after the first successful session.

Delivery follows a conservative ladder:

1. capture the strongest current identity immediately after release inside the frozen process: exact element when exposed, otherwise exact focused window;
2. confirm the target is editable and non-secure;
3. recheck selection and value evidence for concurrent changes;
4. preflight event-post access and use one transactional Command-V for every compatible target while the retained element or window remains current, frontmost, and non-secure;
5. conditionally restore the pasteboard only while Speaker's change count and private marker still match; and
6. preserve the text as a Pending Copy Result only when no paste event was posted.

Speaker does not restore focus, rewrite an entire rich document value, repeat a committed paste, or overwrite a newer user clipboard value. Detailed 2026-07-29 evidence for Chromium/Electron AX behavior, transactional paste timing, and HUD alpha verification lives in [Voice Input AX Delivery and HUD Transparency Best Practices](voice-input-ax-hud-best-practices.md).

## Permission and distribution implications

The deployment target is macOS 14 for the product's SwiftUI and testing surface, not because the core event-tap or Accessibility functions require macOS 14.

A stable signing identity matters because Accessibility and Microphone grants are tied to application identity. Production acceptance therefore includes clean-user installation, upgrade, permission continuity, and revocation/recovery evidence.

## Real-machine evidence

Apple does not define cross-application behavior strongly enough to replace a real support matrix. The required target families and failure cases live in the [compatibility matrix](../compatibility.md).

In particular, evidence must cover built-in/external `Fn`, Fn/Globe settings, real hot-key conflicts, native text fields/views, Safari, Chrome/Electron, rich text, Terminal, secure input, target closure, focus changes, concurrent editing, Unicode, emoji, multiline text, selection replacement, and undo.

## Primary sources

- [CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29)
- [CGEvent flags: maskSecondaryFn](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn)
- [CGEventTapEnable](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29)
- [AXUIElement overview and error contract](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Accessibility attributes](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [WWDC19: Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/)
- [Apple DTS: Accessibility versus Input Monitoring](https://developer.apple.com/forums/thread/828052)
