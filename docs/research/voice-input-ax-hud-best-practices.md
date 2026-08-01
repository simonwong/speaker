# Voice Input AX Delivery and HUD Transparency Best Practices

Last reviewed: 2026-08-01

This note records the strongest platform contracts and implementation evidence found for two current Speaker failures: automatic text delivery that rarely reaches the released input target, and a rectangular surface visible behind the capsule HUD. Apple does not publish a universal cross-application insertion API, so recommendations below distinguish documented contracts from engineering inferences and still require the real-application matrix in [`docs/compatibility.md`](../compatibility.md).

> Implementation correction, 2026-08-01: the focus-cache recommendation below was falsified by same-process, multi-window Terminal use. Speaker now freezes only the frontmost PID in the event callback and queries that process's current focused element/window immediately afterward. The detailed cache design remains here as research history, not the active architecture; [ADR-0002](../adr/0002-freeze-the-input-target.md) is authoritative.

## Decision summary

- Do not perform Accessibility IPC in the `CGEventTap` callback. Maintain a per-process focus cache with `AXObserver`; the release callback should only freeze the cached element, PID, generation, and timestamp, then return.
- Treat the strongest frozen AX identity as the session's only target. Prefer the focused element; when an application exposes no usable focused element but does expose a focused window, freeze and later revalidate that window and process for transactional paste only. Never reacquire a different later target.
- Do not require the flat `AXValue` plus `AXSelectedTextRange` model for every editable target. Chromium/Electron rich editors and `contenteditable` controls commonly expose marker-range or composite-editor semantics instead of the atomic text-field contract.
- Do not use `AXSelectedText` as a mutation API or route delivery by application. For native, browser, Electron, and terminal compatibility, use one transactional pasteboard write followed by one physical Command-V after the strongest available target revalidation.

The 2026-07-30 ChatGPT smoke exposed two additional adapter facts: its focused element may be absent while its focused window remains available, and optional attributes can return `kAXErrorNoValue`. Speaker treats `noValue` and non-CFRange text-marker evidence as missing atomic capabilities rather than rejecting the whole target. This is observed application behavior, not a universal Apple guarantee.
- Window transparency flags are necessary but not sufficient. Mask the actual `NSVisualEffectView` to the capsule shape and render the shadow from a separate rounded shape/path; changing `CALayer.isOpaque` does not remove pixels drawn by hosted content.

## 1. Freeze focus without blocking the event tap

### Why release-time AX queries are fragile

Accessibility calls are cross-process messages. Apple documents timeout, `kAXErrorCannotComplete`, invalid-element, unsupported, and not-implemented outcomes. Separately, Core Graphics can disable an event tap that does not return promptly. Therefore, making `AXUIElementCopyAttributeValue` calls from the Fn release callback couples an input-system callback to an unbounded external application's responsiveness.

The recommended design is an inference from these two documented contracts:

1. Observe the active application with `NSWorkspace.didActivateApplicationNotification`.
2. Create a per-PID `AXObserver`, add `kAXFocusedUIElementChangedNotification`, and install its source on a dedicated run loop.
3. Seed and update a lock-protected focus cache outside the event-tap callback. The cached record should include the retained `AXUIElement`, PID, a monotonically increasing generation, and capture time.
4. On Fn release, atomically snapshot that record and enqueue normal application work. Do not call AX, stop audio, or wait for provider work inside the callback.
5. Immediately after the callback returns, asynchronously inspect role, subrole, security, editability, and selection evidence. A missing, stale, or unsupported cache entry fails closed.

Observers are not a complete source of truth: notifications can be unsupported, delayed, or lost when a process or element disappears. Use a hybrid model in which the observer supplies the identity frozen at release and a bounded post-callback query validates that exact identity. A later fresh focus query must never replace the frozen target.

`AXUIElementRef` is a Core Foundation object and can be retained, but retention does not keep the remote UI object alive. `kAXErrorInvalidUIElement` during later validation is an expected target-loss result.

### Electron exposure

Electron documents that Chromium's accessibility tree is enabled automatically when assistive technology is detected. It also documents the application-level `AXManualAccessibility` attribute for forcing accessibility on. A compatibility adapter can attempt to set this flag when attaching to an Electron process, before recording starts; doing so at release is too late and would reintroduce AX work into the event callback. Failure to set it must remain a normal unsupported case.

## 2. Revalidate, then use a compatibility-aware delivery ladder

Before any mutation:

1. Confirm the frontmost PID still equals the frozen PID.
2. Read that application's current focused element outside the event tap.
3. Compare it with the frozen element using Core Foundation equality.
4. Recheck non-secure classification and any captured selection/value evidence.
5. If any check fails or cannot complete, preserve the transcript as Pending Copy without activating an old app or forcing focus.

There is no public API that atomically inserts into an arbitrary historical editing position. Exact-target revalidation is therefore a precondition, not a guarantee of insertion.

### Why the flat AX contract excludes common editors

Chromium's current macOS bridge maps `AXSelectedText` writes to an internal replace-selected-text action and `AXValue` writes to a set-value action. Its complete selected-range implementation is restricted to atomic text fields, while contenteditable and composite rich editors use text-marker-range behavior. Consequently, a gate that requires both `AXValue` and `AXSelectedTextRange` will reject many real browser and Electron composers before delivery is attempted.

Use control-family capabilities rather than one universal attribute set:

| Target family | Capture and validation | Delivery |
| --- | --- | --- |
| Native/atomic text field | Focused element, selected range, value evidence | Transactional paste; value evidence may confirm the receipt |
| Browser `<input>` / `<textarea>` | Atomic text-field evidence when exposed | Transactional paste, verified per browser |
| `contenteditable`, Monaco, CodeMirror, Electron rich editor | Element identity plus marker-range/composite-editor evidence where available | Prefer target-revalidated paste; do not require flat AX range/value |
| Terminal-like control | Exact focused element and non-secure status | Target-revalidated paste, tested per app |
| Secure or unprovable target | Fail closed | Pending Copy only |

Do not use a generic `AXValue` write as an insertion fallback. It may replace the entire field, and it can bypass the target application's paste, undo, rich-text, or DOM editing path.

### Transactional paste pattern

Pindrop and VoiceInk both converge on pasteboard plus a physical Command-V for cross-application insertion, rather than character-by-character Unicode events. A safe transaction is:

1. Snapshot every pasteboard item and representation that can be restored.
2. Clear the general pasteboard; write the transcript and a private Speaker session marker.
3. Record the pasteboard change count and allow a short stabilization delay.
4. Post an explicit key sequence: Command down, V down, V up, Command up, using a normal session event source.
5. Once V is posted, treat delivery as committed. Do not repeat it or reinterpret a later cancellation as an uncommitted mutation.
6. After a bounded delay, restore the snapshot only if the change count and private marker still prove Speaker owns the pasteboard. If the user copied something else, preserve the user's newer contents.

The open-source implementations use roughly 100-120 ms before paste, 10-50 ms between key events, and 250-500 ms before conditional restoration. Those values are implementation evidence, not platform guarantees; Speaker should tune them against the support matrix.

`CGEvent.keyboardSetUnicodeString` is not a universal alternative: Apple notes that frameworks may ignore the embedded Unicode string and translate the virtual key code themselves. `CGEventPostToPid` also provides no delivery receipt. Clipboard write success proves only that the pasteboard accepted data, not that the target inserted it, so product state should describe this route as a committed paste attempt unless stronger target-specific receipt evidence exists.

## 3. Make HUD shape ownership explicit

### Why the rectangle survives current transparency flags

The following properties solve separate problems:

- `NSWindow.isOpaque = false` allows the window to contain transparent regions.
- `NSWindow.backgroundColor = .clear` prevents the window background from filling them.
- `NSWindow.hasShadow = false` disables AppKit's window shadow.
- `NSView.wantsLayer = true` enables layer backing.
- `CALayer.isOpaque = false` is a backing-store/compositing hint; it does not erase pixels or prevent a subview from drawing an opaque rectangle.

Thus a clear, nonopaque panel can still show a rectangular `NSVisualEffectView`, hosting surface, or SwiftUI effect/shadow. Applying `clipShape` and `.shadow` outside an `NSViewRepresentable` also leaves ambiguity about which subtree contributes alpha and which bounds SwiftUI uses for the shadow.

### Recommended view hierarchy

Keep the borderless, nonactivating `NSPanel` with a clear background, `isOpaque = false`, `hasShadow = false`, and `canBecomeKey = false`. Inside it:

1. Use a nonopaque root/hosting container.
2. Put the behind-window `NSVisualEffectView` in a view whose bounds exactly match the capsule.
3. Mask the visual-effect view itself. AppKit exposes `NSVisualEffectView.maskImage`; a stretchable capsule/rounded-rectangle alpha mask is the most explicit public API. A layer corner radius with `masksToBounds` on the actual effect view is a simpler alternative if its rendering is verified.
4. Render the shadow in a sibling rounded-shape view/layer with an explicit rounded `shadowPath`. Do not attach a generic SwiftUI `.shadow` to the entire hosting or representable subtree.
5. Update the effect frame, mask, and shadow path together whenever HUD size changes.

SwiftUI's shape-aware `background(_:in:)` is appropriate when SwiftUI material semantics are sufficient. For a HUD that must blur content behind a cross-application panel, an explicitly masked `NSVisualEffectView` is the clearer AppKit contract because `behindWindow` and `maskImage` directly describe that behavior.

## 4. Verification that catches the reported failures

Property-only tests cannot prove transparent pixels. Add two complementary checks:

- A structural spec verifying the panel is nonactivating/non-key, clear, nonopaque, shadowless, and that the actual effect surface owns a nonrectangular mask while the shadow uses a rounded path.
- A rendered regression on a high-contrast background. Capture the panel and assert the outer corner pixels remain transparent/unchanged while pixels inside the capsule differ. This specifically catches a rectangular hosting, visual-effect, or shadow surface.

For delivery, test both state invariants and a real-app matrix:

- no AX calls occur on the event-tap callback path;
- delayed/missing observer notifications fail closed and never retarget;
- focus change during recognition yields Pending Copy;
- pasteboard ownership changes prevent stale snapshot restoration;
- one committed paste cannot be repeated by cancellation or late provider results;
- TextEdit/NSTextView, Safari and Chrome input/textarea/contenteditable, VS Code/Monaco, Slack/Codex Electron, Terminal, Unicode/emoji/multiline, closed targets, and secure fields are exercised on a real Mac.

The development command `./scripts/delivery-e2e-smoke` covers the gap between
an event-post success and a real insertion receipt. Its isolated AppKit target
owns a normal Edit/Paste command and reports success only after its `NSTextView`
contains the exact expected text. Speaker reaches it through the production
Voice Input Session orchestration and transactional paste adapter; the fake
text processor avoids a paid provider request while leaving capture and
delivery live.

## Primary sources

### Apple

- [CGEvent tap creation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29), [`tapDisabledByTimeout`](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout), and [enabling a tap](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29)
- [AXUIElement overview and error contract](https://developer.apple.com/documentation/applicationservices/axuielement_h), [messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout), [attribute writability](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable), and [attribute mutation](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [`kAXFocusedUIElementAttribute`](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes/kaxfocuseduielemenattribute), [`kAXFocusedUIElementChangedNotification`](https://developer.apple.com/documentation/applicationservices/kaxfocuseduielementchangednotification), [`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification), and [`AXObserverGetRunLoopSource`](https://developer.apple.com/documentation/applicationservices/1459139-axobservergetrunloopsource)
- [`NSWorkspace.didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [`NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard), [`clearContents`](https://developer.apple.com/documentation/appkit/nspasteboard/clearcontents%28%29), and [`changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
- [`CGEvent.keyboardSetUnicodeString`](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring%28stringlength%3Aunicodestring%3A%29), [`CGEvent.postToPid`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29), and [`CGEventSourceStateID`](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)
- [`NSWindow.isOpaque`](https://developer.apple.com/documentation/appkit/nswindow/isopaque), [`backgroundColor`](https://developer.apple.com/documentation/appkit/nswindow/backgroundcolor), [`hasShadow`](https://developer.apple.com/documentation/appkit/nswindow/hasshadow), [`NSView.isOpaque`](https://developer.apple.com/documentation/appkit/nsview/isopaque), and [`CALayer.isOpaque`](https://developer.apple.com/documentation/quartzcore/calayer/isopaque)
- [`NSVisualEffectView`](https://developer.apple.com/documentation/appkit/nsvisualeffectview), [`behindWindow`](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow), and [`maskImage`](https://developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage)
- [SwiftUI `Material`](https://developer.apple.com/documentation/swiftui/material) and [shape-aware background](https://developer.apple.com/documentation/swiftui/view/background%28_%3Ain%3Afillstyle%3A%29)

### Direct implementation evidence

- [Electron accessibility](https://www.electronjs.org/docs/latest/tutorial/accessibility/)
- [Chromium macOS AX bridge](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm) and [contenteditable selection fixture](https://chromium.googlesource.com/chromium/src/+/bac0f6c262e1dce0008d7ebef05776a5123fbd0a/content/test/data/accessibility/mac/selection/set-selection-contenteditable.html)
- [Pindrop focus tracker](https://github.com/watzon/pindrop/blob/main/Pindrop/Services/FloatingIndicatorFocusTracker.swift) and [paste transaction](https://github.com/watzon/pindrop/blob/main/Pindrop/Services/OutputManager.swift)
- [VoiceInk paste transaction](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Paste/CursorPaster.swift)
- [Chromium transparent overlay hierarchy](https://chromium.googlesource.com/chromium/src/+/1f71c6ec3d33ac53f8e2474fbfd9e6396f731008/chrome/browser/ui/cocoa/tabs/tab_window_controller.mm)
