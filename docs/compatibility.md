# Speaker Compatibility Matrix

Last consolidated: 2026-07-18

This matrix separates deterministic contract evidence from behavior that only a real, unlocked Mac can establish. An unverified Input Target always falls back to a Pending Copy Result.

## Automated contract evidence

| Scenario | Expected contract |
| --- | --- |
| No editable target | Preserve final text as a Pending Copy Result without changing the clipboard |
| Focused element with no editable signal (no text role, settable value, selected text range, or editable ancestor) | Preserve final text as a Pending Copy Result (`missingTarget`) without pasting |
| Window-scope target (no focused element exposed) | Paste-only delivery; the Session Record keeps no transcript text because the security class is unknown |
| Secure target | Reject automatic delivery and keep the Session Record free of text and provider request identifiers |
| Closed or invalid target | Preserve final text as a Pending Copy Result |
| Target content or selection changes while waiting | Fail closed instead of overwriting concurrent work |
| Focus moves within the same application | Reject the original target because the exact focused AX element changed |
| Duplicate press or release events | Submit one Voice Input Session at most once |
| Fast press/release ordering | Preserve the release edge through recorder startup and ordered dispatch |
| User Cancellation during provider work | Cancel local tasks and suppress late Stage Results |
| User Cancellation after delivery commit | Close the HUD while receipt and Session Record settlement retain the real mutation outcome |
| Shutdown with active work | Fence trigger intake, cancel external work, and wait for local persistence |
| Definite silence or a sub-300 ms recording | Cancel provider work and deliver no text |
| Doubao error followed by socket close | Preserve the explicit provider error rather than overwriting it with a secondary send/close error |
| DeepSeek failure | Preserve and deliver the confirmed Doubao Stage Result |
| Paste receipt delay | Wait for the bounded expected-value receipt instead of reporting an instantaneous stale value as failure |
| Posted paste cannot be confirmed | Record a posted-unconfirmed outcome; never expose retryable Pending Copy after the command may have inserted text |
| Voice Input Session to an isolated native editor | Run the real press/release, release-time target capture, processing, and transactional paste path; the target process must read back the exact expected text |
| Pasteboard changes after Speaker prepares delivery | Preserve the newer clipboard value instead of restoring Speaker's stale snapshot |
| Slow clipboard reader, such as a remote desktop or virtual machine | Keep the transcript on the clipboard until the target reads it; restore 100 ms after the first read, no sooner than 500 ms and no later than 3 s after Command-V |
| Target value over 20,000 characters | Read only `AXNumberOfCharacters`; paste once without a receipt and record posted-unconfirmed |
| Long target value within the limit | Read a window of 256 characters on each side of the selection with `AXStringForRange` for the pre-paste check and the receipt; fall back to a capped whole-value read when the range read is unavailable |
| Edit outside the evidence window | Detected when it changes the value's length; an edit that keeps the length is not detected |
| Readable target shows a third value after paste | Never paste again; keep the result as Pending Copy (`deliveryUnconfirmed`) for the user to check first |
| Clipboard over the snapshot budget | Leave the clipboard untouched and keep the result as Pending Copy (`clipboardTooLarge`); an explicit copy replaces it |
| Target application does not complete AX IPC | Preserve the exact read/write stage in a content-free diagnostic |
| Explicit copy | Verify the clipboard value after writing; retain the Pending Copy Result if verification fails |
| Event tap disabled by the system | Reset gesture ownership, re-enable the tap, and surface recovery state |
| Secure Event Input appears during recording | Cancel the active session and stop shortcut capture safely |
| Secure Event Input is on at shortcut press | Consume the press without starting a session; show one short note naming the holding App when known |
| Keyboard layout moves V (for example Dvorak) | Post Command with the key that produces `v` on the current layout; fall back to the ANSI V key code |
| Unicode, emoji, multiline text, and selection replacement | Preserve Swift string content and mutate only the revalidated selection |
| Owner-only local files | Reject symlinks, foreign owners, non-regular files, and oversized documents without overwriting them |
| Credential migration | Migrate only when every source is readable and all non-empty values agree |
| Retention deletion with a busy checkpoint | Keep the committed policy and retry physical WAL convergence later |

The deterministic suite remains the source of current case counts and implementation evidence; [production readiness](production-readiness.md) records the latest verified commands.

On an unlocked development Mac, `./scripts/delivery-e2e-smoke` adds a narrow
real-event check: it launches an isolated native editor, runs the installed
Speaker through a complete Voice Input Session with fixed local text, and exits
successfully only when the target process observes that exact text. It makes no
provider request and does not replace the cross-application matrix.

## Real-machine cross-application matrix

Run `./scripts/compatibility-smoke` on an unlocked Mac with Microphone and Accessibility permission. The report contains no transcript text, credentials, request bodies, or absolute application path. It binds the candidate version, signing mode, and executable SHA-256. Production old-version evidence also requires `--upgrade-from` and the candidate prerelease's immutable `--staging-feed`; the Sparkle case launches the old App with that feed override.

| Target or scenario | Exercise | Acceptance |
| --- | --- | --- |
| Built-in and external-keyboard `Fn` | Hold, speak, and release | Exactly one recording and submission; while selected, Speaker consumes the Fn/Globe action |
| Custom shortcut | Register an available combination, then a conflicting one | The available shortcut works; the conflict is rejected with a recoverable fallback |
| TextEdit plain text | Cursor insertion, selection replacement, undo | The shared transactional paste path inserts once and native undo remains usable |
| Safari editable controls | Text input, textarea, contenteditable, secure field | Supported controls deliver; secure or uncertain controls produce a Pending Copy Result |
| Chrome or Electron editor | Plain input and rich editor | The same transactional paste path is used; readable controls may confirm insertion and other controls report posted-unconfirmed without retry |
| App exposes focused window but no usable focused element | Capture the current window immediately after release as a paste-only target; reject a later window or process |
| Rich-text editor | Emoji, multiline text, selection replacement, undo | Surrounding formatting remains intact or delivery falls back before mutation |
| Terminal | Insert a harmless token at the active command position | Revalidate the exact target, post at most one transactional paste with no newline, and preserve clipboard ownership |
| Focus change | Change windows during recording and change applications after release | Post-release capture follows the current window only inside the release-time process; later changes invalidate that target |
| Target close or concurrent edit | Close the target or modify it while waiting | Preserve the result without overwriting the changed target |
| Login launch | Enable, disable, and log in again | System state and settings agree; the default remains disabled |
| Permission revoke and recovery | Revoke Accessibility or Microphone while running, then restore | Failure is explicit and recovery works without reinstalling |
| Accessibility presentation | VoiceOver, Increase Contrast, and Reduce Motion | Status and cancel actions remain reachable, announced, and visually distinct |

Exit codes protect the evidence contract:

- `0`: the complete matrix passed;
- `1`: at least one case failed;
- `2`: at least one required case was skipped; and
- `3`: an individual `--case` run completed but cannot serve as full release evidence.

## Provider acceptance matrix

Provider acceptance uses user-owned credentials and billed requests. A connection probe proves only credential and resource reachability.

The complete provider matrix covers:

- Doubao transcription for paced 1, 5, 15, and 60 second audio;
- punctuation, written-form normalization, Default Smoothing, cancellation, invalid credentials, and resource errors;
- DeepSeek concise cleanup, full rewrite, Custom Mode, cancellation, invalid credentials, malformed output, truncation, and abnormal expansion fallback; and
- exact source commit, clean worktree, dependency-lock hash, candidate version/build, operating system, architecture, credential source, resource, and model binding.

Provider evidence contains only fixed case identifiers, PASS/FAIL state, stable error classifications, and allow-listed request identifiers or status codes. Any missing, duplicate, failed, skipped, stale, dirty-source, or development-credential case fails production verification.

## Evidence discipline

- Treat automated specifications, a development probe, a provider matrix, and a production-signed cross-application matrix as different evidence classes.
- Re-run permission and target-family smoke after a signing-identity change; historical TCC entries do not prove the current candidate.
- Never broaden delivery based on an implementation-level success alone. A target family becomes supported only after a receipt-verified real-machine case passes.
- Record a failed or skipped case explicitly. A conservative fallback is acceptable; invented support is not.
