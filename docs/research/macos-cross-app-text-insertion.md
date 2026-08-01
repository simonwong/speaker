# macOS cross-application text insertion

**Status:** research and implementation audit, updated 2026-08-01
**Scope:** macOS 14+ menu-bar dictation; TextEdit, Safari, Chrome, Electron, and Terminal
**Decision sought:** the portable delivery primitive and the evidence required before Speaker claims delivery

## Executive conclusion

Speaker should use **Accessibility to capture and revalidate the Input Target, and one transactional Command-V to perform the edit**. That should be the default for TextEdit as well as browser, Electron, and terminal-like editors. Speaker should not use `AXSelectedText` as a portable write API, should not replace the complete `AXValue`, and should not try to type arbitrary Unicode through synthetic key events.

Two implementation choices present at the start of this audit were concrete portability defects:

1. Speaker routes only TextEdit through `AXUIElementSetAttributeValue(..., kAXSelectedTextAttribute, ...)` ([current allow-list](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L173-L180), [write](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L810-L821)). Apple's current SDK declares `AXSelectedText` **not writable** and `AXSelectedTextRange` writable. Chromium happens to implement an `AXSelectedText` setter, but that is an implementation extension rather than the portable Apple contract. This explains the reported asymmetry—Codex uses Speaker's paste fallback while TextEdit takes the nonportable direct-write path—and is the highest-confidence cause of the TextEdit failure.
2. Speaker creates paste events with `.privateState` ([current code](../../Sources/SpeakerCore/VoiceInput/TransactionalPasteboardDelivery.swift#L75-L109)). Apple says programs posting events from a user login session should use `.combinedSessionState`; `.privateState` is intended for specialized software that deliberately maintains independent event state, such as remote-control software ([Apple `CGEventSourceStateID`](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)). This is a second plausible cross-application compatibility defect and must be exercised with real targets.

There is no universal macOS API that both inserts into every third-party editor and returns an insertion receipt. `CGEvent.post` and `postToPid` return `Void`, so “the paste events were posted” is not proof that the target accepted the edit ([Apple `CGEvent.post`](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29), [`postToPid`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29)). Speaker therefore needs two distinct outcomes: **confirmed insertion** when the target can be read back, and **paste command posted, unconfirmed** otherwise. Real-app, target-observed acceptance evidence—not Speaker's own success report—is required for the compatibility claim.

## Implementation correction: same-process window switching

The original audit recommended an `AXObserver` focus cache as the release-time identity source. Real multi-window Terminal use falsified that recommendation for Speaker's reliability goal: the first session could succeed, a same-process window switch could leave the cache pointing at the old element, and all later captures would fail as invalidated. `NSWorkspace` activation does not fire for a window switch inside one process, while Accessibility focus notifications may be delayed or unsupported.

Speaker now freezes only the frontmost PID in the event callback and performs one fresh focused-element/window query in that exact process immediately after the callback returns. Delivery still validates the resulting exact target before posting Command-V. This keeps AX IPC out of the event tap and prevents cross-process retargeting, while accepting a small release-to-query interval in exchange for removing the observer's stale-cache failure mode. Application identity is not part of delivery selection and is no longer displayed, searched, or written to new Session Records.

## Decision addendum: “the current focused input”

This addendum narrows the product decision after reversing the design from the user's actual goal: write into whichever editable control the user is addressing, independent of application identity. It relies only on Apple, Chromium, and Electron primary sources.

### 1. Use one general insertion mechanism, not an application allow-list

**Decision:** remove application-based selection of the mutation primitive. TextEdit, Safari, Chrome, Electron, and other ordinary editors should all use the same general pasteboard-plus-Command-V path. An application matrix remains useful for acceptance evidence and known limitations, but must not select a different write algorithm.

Apple documents `AXSelectedText` as read-only in the macOS SDK, while Chromium implements its own setter by translating it to `kReplaceSelectedText` ([Chromium source](https://chromium.googlesource.com/chromium/src/%2B/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm#3075)). That difference is exactly why a direct AX-write allow-list is structurally fragile. `AXValue` is not a substitute because its meaning is role-specific and a write can replace the complete value. Chromium contenteditable controls additionally use text-marker semantics rather than a universal flat range ([Chromium contenteditable fixture](https://chromium.googlesource.com/chromium/src/%2B/bac0f6c262e1dce0008d7ebef05776a5123fbd0a/content/test/data/accessibility/mac/selection/set-selection-contenteditable.html)). Electron's `AXManualAccessibility` is only a way to expose Chromium's tree; it is not an insertion API ([Electron documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility)).

### 2. Keep target identity only for the lifetime of one delivery

The application name is not needed for insertion. Speaker keeps it only as transient adapter diagnostics; legacy history fields remain decodable, but new Session Records do not write or display application identity. PID, window, and AX element are transient safety evidence and must not be serialized as durable product data.

Automatic insertion still needs a **transient Input Target token** from shortcut release until the delivery attempt. At minimum it contains the frontmost PID and focus generation; when AX exposes them, it also contains the exact focused element and focused window. Apple provides the system-wide AX object for finding the focused object and `AXUIElementGetPid` for ownership ([Apple `AXUIElementCreateSystemWide`](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide)). The retained AX reference is identity evidence only; it does not keep the remote control alive and may become invalid before delivery.

After delivery, failure, cancellation, or timeout, discard the token. A continuously running focus observer may keep only the latest in-memory cache needed to snapshot release without blocking the shortcut callback. It is implementation state, not history.

### 3. Define focus at release as intent and focus at return as validation

**Recommended user-visible contract:** “Speaker inserts into the input focused when recording ends, only if that same input is still focused when the transcript is ready.”

- **At recording end:** snapshot the intended target. This is the user's last unambiguous destination gesture.
- **When the result returns:** re-read frontmost PID and focused AX identity. Use this second observation only to validate the frozen token; never retarget to a newly focused control.
- **If PID, window, exact element, focus generation, or security state changed:** do not post Command-V; return Pending Copy.
- **If the application exposes no exact focused element:** PID-plus-window-plus-unchanged-generation is only weak evidence. It may be offered as an explicitly accepted compatibility tier, but cannot make a no-mispaste guarantee because two inputs can share one window. The safe default is Pending Copy.

Capturing only when the result returns would be simpler, but it changes the meaning to “paste wherever focus happens to be later.” A user can switch into search, chat, Terminal, or a secure field while transcription is running. There is no Apple API that proves this new focus is the user's intended speech destination. Conversely, blindly restoring/activating the release-time application can steal focus and route into a different first responder. Neither behavior is recommended.

This release-freeze/return-validate rule follows Apple's distinction between the frontmost application and focused accessibility object ([Apple system-wide focus API](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide), [`NSWorkspace.frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication), [`kAXFocusedUIElementChangedNotification`](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementchangednotification)). It narrows but cannot eliminate the final race between validation and cross-process event routing.

### 4. Do not promise literally “any input”

The defensible promise is: **“Automatically paste into compatible nonsecure inputs that remain focused; otherwise keep the text available for manual paste.”** Literal support for every focused input is impossible under the public contracts because:

- secure text fields and Secure Event Input must fail closed ([Apple secure AX subrole](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole), [Terminal Secure Keyboard Entry](https://support.apple.com/en-il/guide/terminal/trml109/mac));
- Accessibility or event-synthesizing access can be absent ([Apple AX trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [`CGPreflightPostEventAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29));
- custom canvas editors, remote desktops, browser rich editors, and Electron controls may expose incomplete or non-atomic AX focus/text models; Chromium itself distinguishes atomic text fields from marker-based contenteditable text;
- applications can disable or reinterpret Paste, IME composition and undo are editor-specific, and a Terminal paste containing newline can execute a command;
- `CGEventPost` returns no target receipt, and focus can change after the last check ([Apple event posting](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29)).

These are platform/product boundaries, not cases an app allow-list or another AX setter can remove.

### 5. Minimum one-pass architecture

Implement one pipeline with four small seams:

1. **`FocusedTargetCapture`** freezes the frontmost PID in the release callback, then reads `{ element?, window? }` once in that exact process immediately after the callback and emits an immutable per-session token. Application name is transient diagnostics only.
2. **`TargetValidator`** checks AX trust, event-post access, secure subrole/Secure Event Input, current frontmost PID, and exact focus identity immediately before any pasteboard mutation and again immediately before posting.
3. **`PasteboardTransaction`** snapshots what can be restored, writes transcript plus a unique marker, posts one physical Command-down/V-down/V-up/Command-up sequence from `.combinedSessionState` into the normal event stream, and restores only while marker **and** change count still prove ownership. Apple explicitly recommends combined-session state for programs posting within a login session ([Apple `CGEventSourceStateID`](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)) and change-count comparison for pasteboard ownership ([Apple `NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)).
4. **`DeliveryReceipt`** reports `confirmedInsertion`, `pasteCommandPosted`, or `pendingCopy(reason)`. Only target readback may produce confirmed insertion; a successful `Void` event-post call may produce posted-unconfirmed at most.

Do **not** add or preserve: per-app delivery allow-lists, direct `AXSelectedText` writes, whole-`AXValue` replacement, character-by-character Unicode events, `CGEventPostToPid` as a focus substitute, application activation/focus restoration, durable AX/PID storage, blind retry after posting, or a success test based only on Speaker's own report.

## Source hierarchy and confidence

This report uses sources in this order:

1. Apple documentation and the declarations/comments in the installed macOS SDK.
2. Chromium and Electron first-party implementation/documentation for Chromium-specific behavior.
3. Direct source code from VoiceInk and Pindrop as evidence of patterns used by other dictation tools. These projects do **not** define a macOS platform contract.
4. Speaker's current code and test/docs surfaces.

“Documented” below means an Apple contract. “Observed implementation” means source evidence that still requires compatibility testing. A timing value from another app is not treated as a universal requirement.

## Apple platform contracts

### Accessibility attributes are evidence, not one universal editor API

The installed macOS SDK documents the following in `AXAttributeConstants.h`:

| Attribute | Apple contract | Consequence for Speaker |
| --- | --- | --- |
| `kAXSelectedTextAttribute` | Current selected text; **Writable: No**; required for editable text elements | Read it as evidence. Do not make it Speaker's portable mutation primitive. |
| `kAXSelectedTextRangeAttribute` | Current character range; **Writable: Yes** | It can support selection evidence for controls that expose a flat range, but setting a selection is not inserting text. |
| `kAXValueAttribute` | A catch-all, generally writable when appropriate; the data type and semantics depend on the role | A whole-value write can replace the entire field/document and bypass the editor's normal paste, DOM, rich-text, and undo path. It is not a safe generic insertion fallback. |

Primary source: macOS SDK 26.2 at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXAttributeConstants.h`, lines 314-342 and 683-723; online symbols: [`kAXSelectedTextAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [`kAXSelectedTextRangeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute), and [`kAXValueAttribute`](https://developer.apple.com/documentation/applicationservices/kaxvalueattribute).

Even for an attribute that is documented writable, Speaker must ask the concrete element with `AXUIElementIsAttributeSettable` and handle the result of `AXUIElementSetAttributeValue`; a runtime “settable” answer does not turn a documented read-only attribute into a cross-application contract ([Apple Accessibility element API](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide), [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)). `kAXErrorNoValue` means that an attribute currently has no value; it must remain distinct from unsupported attributes, invalid elements, and an unresponsive target.

### Capture the target with AX, then freeze it

Apple describes the system-wide AX element as the way to find the focused object regardless of the active application ([`AXUIElementCreateSystemWide`](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide)). `AXUIElementGetPid` provides the owning process. `kAXFocusedUIElementChangedNotification` reports a focus change ([Apple notification](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementchangednotification)); the current SDK also warns that its callback value may be the **application element when nothing has focus**. `kAXFocusedWindowChangedNotification` is a separate notification.

The frozen Input Target should therefore contain:

- the owning PID;
- the exact focused element identity, when available;
- the exact focused window identity;
- a capture generation/timestamp for diagnostics;
- security evidence and the minimal available value/selection evidence.

At delivery, Speaker should verify the same PID is frontmost, the same element/window is focused, the target is not secure, and any captured stable evidence still matches. It must never activate the old app, reacquire a new focused element, or redirect to another control. This preserves [ADR 0002](../adr/0002-freeze-the-input-target.md).

Speaker currently observes only focused-element changes ([observer registration](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L326-L349)) and caches the callback element without rejecting an application-level callback payload ([callback](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L473-L489)). It should also observe focused-window changes and qualify the cached role/ownership before treating the callback value as an Input Target. Otherwise the window fallback can be stale, and an application element received during “no focus” can be mistaken for a paste target.

### Accessibility trust and event-post access are separate checks

`AXIsProcessTrustedWithOptions` is the Accessibility trust preflight; requesting a prompt is asynchronous and does not make the current call trusted ([Apple `AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)). Core Graphics separately exposes `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` for event synthesizing access ([Apple preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29), [request](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29)). Speaker should preflight both capabilities and represent failure before changing the pasteboard.

The permission contract is tied to the signed app identity. Acceptance must run the exact signed candidate, not an ad-hoc rebuild with different TCC identity.

### Event stream versus `postToPid`

Apple defines `CGEventPost` as inserting an event into the event stream at a tap location. `CGEventPostToPid` sends an event to a process. Both return `Void`; neither proves first-responder routing, editability, or insertion ([current SDK `CGEvent.h` declarations](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29)).

For Speaker, the ranked choice is:

1. **Normal event stream after exact frontmost/focus revalidation.** This most closely follows the user's ordinary Command-V route through the visible application's current responder.
2. **Do not adopt `postToPid` as a reliability fix.** A PID does not identify a window or editor. It can send events to the frozen process after it stops being frontmost, or to a different first responder inside the same process. It still provides no receipt.

There remains an unavoidable race between revalidation and event routing. Speaker can narrow it but cannot make arbitrary cross-process insertion atomic. Any focus change observed before the paste sequence must fail closed; a change after posting cannot safely cause a second attempt.

Apple's keyboard-event initializer requires the caller to provide the key transitions, including modifier transitions ([Apple keyboard event initializer](https://developer.apple.com/documentation/coregraphics/cgevent/init%28keyboardeventsource%3Avirtualkey%3Akeydown%3A%29)). The portable sequence to test is physical Command down, physical V down, V up, Command up, using `kVK_ANSI_V`, `.combinedSessionState`, and the normal event stream. Command up must be emitted best-effort even if a later construction/posting step fails, to avoid a stuck modifier.

Synthetic Unicode events are not a universal alternative. Apple says application frameworks may ignore the event's Unicode string and instead derive text from virtual key code and event state ([`CGEventKeyboardSetUnicodeString`](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring%28stringlength%3Aunicodestring%3A%29)). Character-by-character injection also has worse selection, multiline, keyboard-layout, IME, and undo behavior than one paste command.

### Paste is the broad edit path, but behavior remains target-specific

AppKit's standard text system pastes at the insertion point or replaces the selection. `NSTextView` owns selection/modification, rich text, input management, marked text, key bindings, and optional undo ([Apple `NSTextView`](https://developer.apple.com/documentation/appkit/nstextview), [`NSTextInputClient`](https://developer.apple.com/documentation/appkit/nstextinputclient), [`allowsUndo`](https://developer.apple.com/documentation/appkit/nstextview/allowsundo)). This is why sending the target its ordinary paste command is preferable to replacing `AXValue` or mutating a remote AX string.

This is not a guarantee that every custom editor preserves one-step undo, active IME composition, formatting, or DOM events. A paste may commit/cancel marked text, a web editor may sanitize content, a terminal may bind Command-V differently, and an app can disable Paste. These are acceptance-matrix questions, not assumptions.

### Clipboard ownership and restoration

Apple says `NSPasteboard.changeCount` increases whenever ownership changes and explicitly recommends recording and comparing it to determine whether the caller still owns the pasteboard ([Apple `changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)). Speaker's current **change count AND private marker** predicate is appropriately conservative ([transaction](../../Sources/SpeakerCore/VoiceInput/TransactionalPasteboardDelivery.swift#L43-L65)): a newer user clipboard write must always win.

The recommended transaction is:

1. Snapshot the existing items and the representations Speaker is prepared to restore.
2. Clear the general pasteboard, write a plain string and a unique private marker, and record the resulting change count.
3. Wait only long enough for pasteboard propagation, then revalidate security, PID, focus, and ownership.
4. Post exactly one complete Command-V sequence.
5. After a bounded delay, restore only if both the change count and marker still match.
6. If Speaker no longer owns the pasteboard, never restore and never post a second paste.

Restoration is best effort, not lossless in all cases. Apple supports lazy pasteboard data providers, so calling `data(forType:)` can force promised representations to materialize; an `NSPasteboardItem` also becomes stale when ownership changes ([Apple data-provider protocol](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider), [`NSPasteboardItem`](https://developer.apple.com/documentation/appkit/nspasteboarditem)). Current AppKit also exposes a user-controlled `accessBehavior` for programmatic general-pasteboard reads ([Apple `NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)). Speaker must define what happens when the snapshot is partial or denied: the safe choice is to avoid promising exact restoration, and never overwrite a later clipboard value.

### Secure input and secure fields

Speaker must reject a target whose AX subrole is `AXSecureTextField` ([Apple secure text-field subrole](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole)). It should also conservatively refuse automatic insertion while `IsSecureEventInputEnabled()` is true. Apple's SDK describes secure event input as routing keyboard input only to the focused application and hiding it from monitoring clients; it does not promise that every synthetic event is rejected. The global veto is therefore a Speaker safety policy, not an insertion-receipt mechanism.

Terminal exposes a user-visible Secure Keyboard Entry mode ([Apple Terminal guide](https://support.apple.com/en-il/guide/terminal/trml109/mac)). The real-app matrix must cover it explicitly.

## Chromium and Electron constraints

Electron documents `AXManualAccessibility` as a third-party switch that exposes Chromium's accessibility tree ([Electron accessibility](https://www.electronjs.org/docs/latest/tutorial/accessibility)). The attribute is not in Apple's SDK. It should be isolated as a Chromium/Electron compatibility adapter, attempted when attaching to a known Electron process, and treated as optional. It must not be the foundation of the Apple target model.

Chromium's current macOS bridge implements an `AXSelectedText` setter by dispatching its internal `kReplaceSelectedText` action, and implements an `AXValue` setter as an internal set-value action ([Chromium Cocoa bridge](https://chromium.googlesource.com/chromium/src/%2B/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm#3075)). This explains why an AX write can appear to work in one Chromium-derived app despite Apple's read-only declaration; it is Chromium behavior, not cross-app evidence.

Chromium only derives the flat `NSRange` selected-text range for atomic text fields; its contenteditable tests use AX text-marker ranges on an `AXTextArea` ([Chromium bridge](https://chromium.googlesource.com/chromium/src/%2B/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm#3085), [contenteditable selection fixture](https://chromium.googlesource.com/chromium/src/%2B/bac0f6c262e1dce0008d7ebef05776a5123fbd0a/content/test/data/accessibility/mac/selection/set-selection-contenteditable.html)). Therefore a gate that requires flat `AXValue` plus `AXSelectedTextRange` will reject many contenteditable, Monaco, CodeMirror, and Electron editors. For these targets, AX should prove exact focus and security as far as possible; paste should perform the edit; target-observed acceptance should prove the result.

## Evidence from mature open-source dictation tools

These examples are useful convergence evidence, not platform guarantees:

- VoiceInk snapshots pasteboard representations, writes the transcript plus a session marker, waits 100 ms, posts explicit Command/V down/up events with 10 ms gaps, and restores only when its expected text and marker remain. Its result is deliberately named `commandPosted`, not “inserted” ([VoiceInk `CursorPaster.swift`](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Paste/CursorPaster.swift), [`ClipboardManager.swift`](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Paste/ClipboardManager.swift)). VoiceInk also uses `.privateState`; that choice conflicts with Apple's guidance for login-session applications and should not be copied.
- Pindrop describes direct insertion as paste-based, snapshots/restores the clipboard, posts explicit physical Command/V transitions, and explicitly documents that `.pasted` means the keystroke was issued ([Pindrop `OutputManager.swift`](https://github.com/watzon/pindrop/blob/main/Pindrop/Services/OutputManager.swift#L198-L265)). Pindrop uses `.hidSystemState`, reactivates the captured application, and restores when change count **or** text matches ([same source](https://github.com/watzon/pindrop/blob/main/Pindrop/Services/OutputManager.swift#L450-L530)). Speaker should not copy those choices: Apple reserves HID state for hardware/driver sources, application activation violates the frozen-target rule, and OR-based restoration can overwrite a newer clipboard that happens to contain the same text.

The useful convergence is narrow: one pasteboard transaction plus one complete physical Command-V sequence is the broad compatibility path, and “posted” must not be confused with target receipt.

## Audit of Speaker's current implementation

### Findings ranked by likely impact

| Rank | Finding | Evidence | Required direction |
| --- | --- | --- | --- |
| 1 | TextEdit alone uses documented-read-only `AXSelectedText` mutation. | [allow-list](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L173-L180), [mutation](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L810-L821) | Remove the TextEdit direct-write default. Drive TextEdit through the same transactional paste path as Codex. |
| 2 | Paste events use `.privateState`, contrary to Apple's login-session guidance. | [transaction lines 75-109](../../Sources/SpeakerCore/VoiceInput/TransactionalPasteboardDelivery.swift#L75-L109) | Change to `.combinedSessionState`; keep the complete physical four-event sequence and best-effort modifier cleanup. |
| 3 | Event-post authorization is not explicitly preflighted. | Delivery checks AX/security/focus but calls the poster directly ([paste](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L870-L904)). | Check `CGPreflightPostEventAccess` before modifying the clipboard and expose a precise unavailable reason. |
| 4 | A posted command is promoted to `.delivered` when no readback capability exists. | [outcome mapping](../../Sources/SpeakerCore/VoiceInput/AccessibilityInputTargets.swift#L353-L370) | Split confirmed receipt from posted-unconfirmed. Never label the latter target-observed PASS. |
| 5 | Focus cache observes element changes only and accepts an unqualified callback element. | [registration](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L326-L349), [callback](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L473-L489) | Observe window changes, reject application/window payloads as editable elements, and keep exact PID/window/element identities. |
| 6 | Clipboard restore logic is safe against newer writes, but snapshot fidelity is overclaimed if all representations cannot be materialized. | [snapshot and ownership](../../Sources/SpeakerCore/VoiceInput/TransactionalPasteboardDelivery.swift#L15-L50) | Preserve the AND predicate; specify and test partial/denied snapshot behavior. |
| 7 | `AXManualAccessibility` is applied to every observed app even though it is Electron-specific. | [current adapter](../../Sources/SpeakerCore/VoiceInput/AccessibilityTargetSystem.swift#L316-L324) | Isolate behind a Chromium/Electron adapter and treat unsupported/failed writes as normal. |

### Evidence gaps and documentation mismatches

- `frontmost-delivery-smoke` accepts Speaker's own `result=PASS`; `DeliverySmokeRunner` produces that when the domain outcome is `.delivered` ([runner](../../Sources/SpeakerApp/VoiceInput/DeliverySmokeRunner.swift#L173-L188)). Because the general paste path maps `.posted` to `.delivered`, this smoke can pass without target insertion.
- `delivery-e2e-smoke` is materially stronger: its isolated `NSTextView` process emits a target receipt, and the script requires both reports to pass. Keep it as the deterministic native tracer bullet, but do not extrapolate it to Safari, Chrome, Electron, or Terminal.
- [`docs/adr/0002-freeze-the-input-target.md`](../adr/0002-freeze-the-input-target.md) and [`voice-input-ax-hud-best-practices.md`](voice-input-ax-hud-best-practices.md) currently endorse allow-listed direct `AXSelectedText` replacement. That conflicts with the current Apple SDK contract and should be corrected in the implementation ticket.
- [`docs/compatibility.md`](../compatibility.md) says Terminal receives at most one transactional paste, while [`scripts/compatibility-smoke`](../../scripts/compatibility-smoke#L102-L105) says Speaker does not simulate Command-V. Current production code does post Command-V. The matrix and script must state the same policy.

## Ranked recommendation for Speaker

### 1. Establish one portable delivery path

Use AX for capture, identity, focus, and security checks. Use a transactional paste plus one physical Command-V for all nonsecure supported targets, including TextEdit. Remove `AXSelectedText` writes from the default product path. Do not add whole-`AXValue` or Unicode-event fallback paths.

This is the smallest architecture that matches both Apple's contracts and the successful Codex behavior already observed by the user.

### 2. Make event posting correct and narrowly scoped

Use `.combinedSessionState`, physical `kVK_Command` and `kVK_ANSI_V`, explicit down/up transitions, and the normal event stream. Preflight event-post access. Revalidate frontmost PID, exact focus, security, and clipboard ownership immediately before Command down. After Command down, always attempt Command up. Never retry after any event could have reached the target.

Keep timing injectable and bounded. Start with the existing 100 ms pasteboard propagation delay and 10 ms inter-event gap because they are already deterministic seams, but treat them as parameters validated by the acceptance matrix rather than macOS guarantees.

### 3. Deepen the Input Target seam

The Input Target should be an immutable token produced at shortcut release and consumed exactly once. The focus tracker should observe both focused element and focused window, qualify notification payloads, and retain the strongest valid identity. Delivery must not reactivate or retarget.

For an exact focused element that lacks flat value/range evidence, allow paste-only eligibility when PID, element/window focus, role/security checks, and the application support matrix are satisfied. Do not pretend that a focused window alone proves an editable responder; window-only support needs explicit per-application acceptance.

### 4. Separate commit from receipt

Recommended outcome vocabulary:

| Outcome | Meaning | UI/history implication |
| --- | --- | --- |
| `confirmedInsertion` | Target-observed content equals the expected edit | May claim delivered. |
| `pasteCommandPosted` | Commit gate passed and the single paste sequence was posted; target receipt is unavailable | Do not retry. UI may remain unobtrusive, but diagnostics/evidence must say unconfirmed. |
| `pendingCopy(reason)` | No event was posted; text remains available for manual recovery | Show manual-copy UI. |

For atomic readable fields, compute expected before/after content and poll a short bounded AX receipt. For browser test pages, read the DOM from the page harness. For contenteditable or custom editors without a stable production readback, only the live acceptance harness can confirm insertion; production should record posted-unconfirmed. A `Void` Core Graphics call can never produce `confirmedInsertion` by itself.

### 5. Preserve clipboard safety

Keep the marker-plus-change-count AND predicate. Make snapshot quality explicit and test empty, multiple-item, rich representation, lazy-provider, denied-read, external overwrite, and cancellation cases. Never restore over a newer clipboard. If snapshot preparation fails before commit, do not synthesize the paste; leave the transcript recoverable.

## TDD refactor slices

The implementation should proceed as small red-green-refactor slices, in this order:

1. **Red: TextEdit policy.** A capability-policy spec asserts that TextEdit no longer selects direct `AXSelectedText` insertion and uses transactional paste. Green by deleting the TextEdit-only portable exception.
2. **Red: event-source contract.** Make the event source injectable/observable and assert `.combinedSessionState`, physical V, the exact four transitions, and Command-up cleanup. Green by changing the production poster.
3. **Red: authorization.** With event-post preflight false, assert no pasteboard mutation and `pendingCopy(eventPostingUnavailable)`. Green by moving preflight before transaction preparation.
4. **Red: receipt semantics.** A fake poster succeeds without changing target content; assert `pasteCommandPosted`, not `confirmedInsertion`. A readable target eventually reaches the expected value; assert confirmed. Green by splitting outcomes.
5. **Red: focus cache.** Cover focused-window changes, application-element “no focus” callbacks, stale windows, same-PID different elements, cross-PID focus changes, and closed elements. Green by qualifying and freezing the token.
6. **Red: clipboard transaction.** Cover marker mismatch, change-count mismatch, equal text written by another owner, multiple items, partial snapshot, denied read, cancellation before posting, and cancellation after posting. Green without weakening the AND ownership rule.
7. **Red-to-green live tracer bullets.** Run the isolated `NSTextView` receipt test first, then the signed real-app matrix below. A real-app failure is a red acceptance test and must not be converted to “supported” by loosening the receipt definition.

The deterministic tests should fake AX, pasteboard, clock, and event poster through the same interfaces production uses. Timing-only sleeps should not be used as receipt assertions.

## Required real-app acceptance matrix

Run on an unlocked Mac with the exact signed candidate, Accessibility trusted, event-post access preflight passing, and all app versions recorded. Each case must record the frozen PID/target class, delivery outcome, target-observed final content, duplicate count, clipboard result, and undo result. “Speaker reported PASS” is insufficient.

Use a unique harmless token such as `speaker-<run-id>-你好🙂`. Run insertion at an empty cursor and in the middle of surrounding sentinel text. Run selection replacement separately. Include multiline only where it cannot execute a command.

| Target | Cases | Target-observed receipt | Pass criteria |
| --- | --- | --- | --- |
| **TextEdit** | Plain-text and rich-text documents; empty cursor; middle insertion; selection replacement; Chinese, emoji, and multiline; focus switch before delivery | Read the actual document text, not Speaker's result | Exact one-time edit at frozen selection; surrounding content/format intact; one Command-Z restores pre-edit state; clipboard restored only when still owned; focus switch produces Pending Copy and no mutation. |
| **Safari** | Controlled page with `<input>`, `<textarea>`, `contenteditable`, and `<input type=password>`; empty, selection, Unicode, multiline where valid; active IME composition | Test page records DOM value/text and `beforeinput`/`input` observations; also inspect visible text | Ordinary controls receive exactly once through paste behavior; no whole-document replacement; undo behavior recorded; password always Pending Copy/no mutation; focus change fails closed. Do not require a particular DOM-event sequence until measured and specified. |
| **Chrome** | Same controlled page and cases as Safari; include a representative complex contenteditable editor | Same DOM harness plus visible result | Same criteria as Safari; flat AX range absence must not by itself reject a paste-capable contenteditable target; no duplicate insertion. |
| **Codex (Electron)** | Composer plus any available code/Monaco editor; cursor and selection; Unicode/emoji/multiline; focus change | Visible/AX readback when stable; otherwise a test-specific editor receipt | Exact one-time insertion or explicit Pending Copy; no wrong control/window, duplicate, hang, or destructive value replacement. Record whether `AXManualAccessibility` was needed. |
| **Terminal** | Empty shell prompt only; harmless token with **no newline**; selection if supported; Secure Keyboard Entry off/on | Read visible prompt and then clear with Control-U; never execute the token | With secure entry off: exact one-time paste or explicit Pending Copy. With secure entry on: Pending Copy and no synthetic event. Never auto-test multiline/newline because it can execute commands. Undo is not a portable terminal criterion; clipboard ownership still is. |

Cross-cutting cases for every supported target:

- target app changes after release;
- focused element changes within the same PID;
- target closes or becomes unresponsive;
- user copies something new during the transaction;
- cancellation before commit and after command posting;
- event-post preflight unavailable;
- clipboard snapshot unavailable or partial;
- keyboard layout where Command modifies layout behavior;
- ten repeated runs per case to reveal timing/race failures.

Compatibility may be claimed only for the exact target family and behavior exercised. A browser `<input>` pass does not prove `contenteditable`; an Electron composer pass does not prove Monaco; the isolated `NSTextView` helper does not prove TextEdit or a browser.

## Proposed issue acceptance boundary

The implementation issue should remain open until the user validates the signed app against at least TextEdit, Safari, Chrome, Codex/Electron, and Terminal. Its completion criteria should include:

- no production `AXSelectedText` mutation path;
- `.combinedSessionState` and explicit event-post preflight;
- one frozen target and no application reactivation/retargeting;
- one command sequence maximum after commit;
- confirmed-versus-posted outcome semantics;
- conditional clipboard restore that never overwrites a newer owner;
- deterministic specs and isolated target receipt passing;
- completed real-app matrix with target-observed evidence;
- ADR, compatibility documentation, and smoke-script wording updated to the implemented behavior.

This report is the problem/solution record. It intentionally makes no production-code change and does not itself assert that the recommended implementation has passed the real-app matrix.

## Implementation status

GitHub issue [#14](https://github.com/simonwong/speaker/issues/14) applies this decision in the working tree: the application allow-list and direct `AXSelectedText` mutation path are removed, paste events use combined-session state, event-post access is preflighted before pasteboard mutation, focus notifications reread application focus, the generic `AXManualAccessibility` mutation is removed, and posted-without-receipt is no longer exposed as retryable Pending Copy. The target-observed isolated native tracer bullet passes through the long-lived application-switch lifecycle.

The signed TextEdit smoke also passes by polling the target's AX value until it exactly matches the expected full edit. Safari, Chrome, Electron, and Terminal acceptance remains tracked by [#15](https://github.com/simonwong/speaker/issues/15).

A Chrome extension-driven experiment was deliberately not counted as evidence: it could establish DOM focus and inject a probe into the page, but that focus did not align with macOS's AX/physical first responder when Speaker posted Command-V. Speaker observed a changed Chrome AX value while the intended DOM `<input>` remained empty. Browser-extension automation therefore cannot certify this system-level interaction; the exact stable signed candidate needs a real user-focus acceptance run. Neither Speaker's own report nor browser-internal focus alone substitutes for target-observed evidence.
