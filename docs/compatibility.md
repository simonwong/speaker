# Speaker Compatibility Matrix

Last consolidated: 2026-07-18

This matrix separates deterministic contract evidence from behavior that only a real, unlocked Mac can establish. An unverified Input Target always falls back to a Pending Copy Result.

## Automated contract evidence

| Scenario | Expected contract |
| --- | --- |
| No editable target | Preserve final text as a Pending Copy Result without changing the clipboard |
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
| AX receipt delay | Wait for the bounded expected-value receipt instead of reporting an instantaneous stale value as failure |
| AX mutation cannot be confirmed | Keep the result recoverable and avoid a delivered claim that could cause duplicate manual insertion |
| Target application does not complete AX IPC | Preserve the exact read/write stage in a content-free diagnostic |
| Explicit copy | Verify the clipboard value after writing; retain the Pending Copy Result if verification fails |
| Event tap disabled by the system | Reset gesture ownership, re-enable the tap, and surface recovery state |
| Secure Event Input appears during recording | Cancel the active session and stop shortcut capture safely |
| Unicode, emoji, multiline text, and selection replacement | Preserve Swift string content and mutate only the revalidated selection |
| Owner-only local files | Reject symlinks, foreign owners, non-regular files, and oversized documents without overwriting them |
| Credential migration | Migrate only when every source is readable and all non-empty values agree |
| Retention deletion with a busy checkpoint | Keep the committed policy and retry physical WAL convergence later |

The deterministic suite remains the source of current case counts and implementation evidence; [production readiness](production-readiness.md) records the latest verified commands.

## Real-machine cross-application matrix

Run `./scripts/compatibility-smoke` on an unlocked Mac with Microphone and Accessibility permission. The report contains no transcript text, credentials, request bodies, or absolute application path. It binds the candidate version, signing mode, and executable SHA-256.

| Target or scenario | Exercise | Acceptance |
| --- | --- | --- |
| Built-in and external-keyboard `Fn` | Hold, speak, and release | Exactly one recording and submission; the system Fn/Globe action is not swallowed |
| Custom shortcut | Register an available combination, then a conflicting one | The available shortcut works; the conflict is rejected with a recoverable fallback |
| TextEdit plain text | Cursor insertion, selection replacement, undo | Delivery is confirmed and native undo remains usable |
| Safari editable controls | Text input, textarea, contenteditable, secure field | Supported controls deliver; secure or uncertain controls produce a Pending Copy Result |
| Chrome or Electron editor | Plain input and rich editor | Confirmed controls deliver; every uncertain control falls back consistently |
| Rich-text editor | Emoji, multiline text, selection replacement, undo | Surrounding formatting remains intact or delivery falls back before mutation |
| Terminal | Insert at the active command position | Deliver only with a confirmed receipt; never simulate paste |
| Focus change | Change applications during recording and again after release | The first target captured at release remains the only target |
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
