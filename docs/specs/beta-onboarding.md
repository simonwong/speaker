# Small-Beta Installation and First-Use Experience

## Problem Statement

Speaker is already being tested by a small group of users. The current first-use experience prevents those users from reaching reliable voice input without help. The development download is a ZIP rather than an installation window. Permission instructions do not clearly distinguish the macOS microphone prompt from the Accessibility settings page. A crowded initial panel mixes permissions, provider configuration, and gesture instructions.

Credential recovery is difficult to discover: the initial setup has no clear deletion path, and a saved or incorrect API Key can leave its replacement editor hidden. The reported workaround is to delete the Key and add it again. Refinement Mode cards can make inactive modes look selected. Very short recordings produce an unnecessary notice, and terminal notices require a mouse click because Esc does not dismiss them. Their close controls also differ from the recording HUD.

## Solution

Provide a DMG with a familiar drag-to-Applications installation window. Guide first use through three visible steps: required permissions, Doubao API Key and connection verification, then a keyboard-shortcut tutorial. Keep credential entry, replacement, and deletion together in both setup and Settings. Present exactly one active Refinement Mode. End very short recordings without a notice, and let users dismiss terminal notices with Esc or the same close-control style used by the recording HUD.

The changes improve the existing small beta. They do not establish production distribution readiness or compatibility with devices and macOS versions that have not been tested.

## User Stories

1. As a beta tester, I want a DMG download, so that I can use the familiar macOS installation flow.
2. As a beta tester, I want Speaker and Applications visible side by side, so that the installation destination is obvious.
3. As a beta tester, I want clear drag-and-open instructions, so that I open the installed App rather than running it from the disk image.
4. As a beta tester, I want the download to retain its verified App signature, so that packaging does not silently change its identity.
5. As a beta tester, I want development signing and notarization limits stated accurately, so that a DMG is not mistaken for production acceptance.
6. As a first-time user, I want one setup step visible at a time, so that I can focus on the next action.
7. As a first-time user, I want the current step and total step count visible, so that I know how much setup remains.
8. As a first-time user, I want the purpose of each permission explained before granting it, so that I understand why Speaker requests access.
9. As a first-time user, I want an unrequested microphone permission to open the macOS permission prompt, so that I can grant it directly.
10. As a user who denied microphone permission, I want instructions for its System Settings page, so that I can recover without guessing.
11. As a first-time user, I want the exact Accessibility settings path and missing-App instructions, so that I can enable the correct installed App.
12. As a user with a restricted permission, I want the restriction explained, so that I do not repeatedly try an action I cannot complete.
13. As a user returning from System Settings, I want permission status refreshed, so that Speaker shows the result of my action.
14. As a first-time user, I want setup to explain why the next step is unavailable, so that an incomplete permission or provider check is actionable.
15. As a first-time user, I want to go back or finish setup later, so that I remain in control of the setup flow.
16. As a first-time user, I want a link to the Doubao console and a provider-resource choice, so that I configure the resource enabled for my own account.
17. As a user configuring a provider, I want to save an API Key without automatically issuing a connection request, so that I choose when provider communication occurs.
18. As a user who entered an incorrect Key, I want the secure editor to remain visible, so that I can replace it in place.
19. As a user with a stored Key, I want to save its replacement without deleting it first, so that correction is a single operation.
20. As a user removing a Key, I want deletion beside replacement with a clear confirmation and consequence, so that I know what will stop working.
21. As a user whose credential write or deletion fails, I want an accurate recoverable error, so that I can retry without believing the credential changed.
22. As a user whose connection check fails, I want to keep access to credential editing, so that recovery does not require leaving setup.
23. As a user who replaces a Key, I want the previous verification state cleared, so that the new credential is not presented as already verified.
24. As a first-time user, I want DeepSeek to remain optional, so that Default Smoothing works with Doubao alone.
25. As a first-time user, I want the tutorial to name my keyboard shortcut explicitly, so that short press and long press are not confused with an on-screen recording button.
26. As a first-time user, I want separate short-press, long-press, and Esc examples, so that I know how to start, finish, and cancel a Voice Input Session.
27. As a user changing a shortcut later, I want Settings to focus on the shortcut choice, so that the onboarding lesson does not clutter the control.
28. As a user selecting a Refinement Mode, I want only the active mode or the Custom Mode I am editing to be highlighted, so that clicking Custom Mode gives clear feedback without highlighting two cards.
29. As a user editing a Custom Mode, I want editing and activation to remain distinct, so that an open editor does not imply that Custom Mode is active.
30. As a user who accidentally records too briefly, I want the recording surface to disappear silently, so that an accidental gesture does not require cleanup.
31. As a user viewing a Session Problem or Pending Copy Result notice, I want Esc to dismiss it, so that I can return to typing without using the mouse.
32. As a user with an active Voice Input Session, I want Esc to retain its cancellation behavior, so that notice dismissal does not change recording or processing cancellation.
33. As a user starting a new Voice Input Session, I want late keyboard events from an earlier session to leave it untouched, so that stale work cannot cancel or dismiss newer work.
34. As a user viewing a floating surface, I want a consistent close control with an accessible action name, so that its appearance and purpose are predictable.
35. As a keyboard or VoiceOver user, I want setup progress, permission changes, and connection results announced, so that the flow does not depend on visual inspection alone.
36. As a returning user, I want to reopen the usage guide from the menu, so that I can review setup and keyboard behavior without resetting completed setup or repeating an online connection check.

## Implementation Decisions

- The installation package accepts an already signed App and preserves its signature and nested bundle structure. It creates an APFS/lzfse DMG containing the App, an Applications link, installation instructions, and a volume-local Finder layout. Packaging does not launch the App or change global Finder preferences.
- Development prereleases publish the DMG and its checksum as human-facing downloads. Their internal CI ZIP remains a transport artifact. Existing release tags are not overwritten. Development signing remains explicitly separate from production Developer ID signing and notarization.
- Production distribution uses the same installation layout while retaining its existing App and DMG notarization, HTTPS feed, Ed25519 verification, immutable artifact promotion, and public readback gates. Packaging does not weaken or replace these gates.
- `SpeakerAppFeatures` owns the three-step presentation, permission instructions, product copy, accessibility announcements, and close-control style. `SpeakerRuntime` and the existing permission coordinator continue to own live lifecycle integration.
- Setup proceeds in the order Permissions → Doubao connection → Keyboard shortcut. Both required permissions must be granted before continuing beyond the first step. A stored Doubao Key and a successful explicit connection check are required before the tutorial can be completed. Going back and deferring setup remain available. The menu offers “使用引导…” to reopen the guide without resetting the completed-setup marker. Users who already completed or deferred setup can browse every step in review mode without repeating permission or connection checks; this does not change recording readiness. Credential writes in progress prevent first-time setup from completing with stale verification.
- Permission actions depend on the observed permission state. An unrequested microphone permission uses the system prompt; a denied permission opens its corresponding settings page. Accessibility instructions identify the settings path and explain adding the installed App when absent. Restricted access is explained without offering an ineffective grant action.
- Returning to the App refreshes permission status. Neither opening the setup window nor advancing a step silently requests permission or checks a provider connection.
- Setup reuses the same Doubao settings card and credential operations as Settings. Both provider cards keep a secure entry field, save or replace action, and stored-Key deletion action together. Deletion requires confirmation that describes its effect. A successful change clears the draft and invalidates previous connection verification; failures remain recoverable without hiding the editor.
- Credential mutation continues through the existing credential-store seam. The change addresses the visible edit and recovery flow; it does not presume a Keychain add/update defect. Synthetic credential-store verification and provider authentication are separate evidence.
- DeepSeek is configured later in Settings when desired. Default Smoothing uses Doubao only. Removing a DeepSeek Key retains Doubao transcription and the established fallback to Default Smoothing.
- The keyboard tutorial explicitly refers to the configured keyboard shortcut. Short press starts and ends recording; long press records while held; Esc cancels unfinished work. The tutorial explains that the Input Target is selected when recording ends. Settings retains shortcut configuration without repeating the gesture tutorial beneath it.
- Refinement Mode cards have one highlighted background and border. Opening Custom Mode moves this highlight to its editor card; the checkmark still identifies the active mode. An inactive custom editor explains that saving and enabling is required and names the current mode. Keyboard focus never creates another highlight. DeepSeek-dependent modes require a stored DeepSeek Key; their availability does not require a successful connection check. Copy must describe that actual requirement. The explicit successful-connection gate applies to Doubao onboarding completion.
- A recording-too-short outcome produces no floating notice and leaves the user free to start another Voice Input Session. This is a presentation change, not a new duration threshold or a change to retained diagnostic and Session Record privacy rules.
- The existing trigger dispatcher routes Esc to cancellation for active work and to dismissal for a terminal Session Problem or Pending Copy Result notice. Presentation ownership and trigger ordering prevent old events from acting on a later session. Dismissing a notice does not perform delivery, copy text, erase history, or convert committed delivery into cancellation.
- Recording and terminal-notice close buttons share one product style while retaining the correct cancel or dismiss action and accessible name.
- The existing ADR boundaries remain intact: Input Target freezing at recording end, microphone freezing at activation, User Cancellation distinct from Session Problems, delivery only after the commit gate, no audio sent to DeepSeek, and no transcript persistence before the Input Target security class is known. No new backend, schema, or provider protocol is introduced.

## Testing Decisions

- Tests assert behavior visible to a caller or user: whether a step can continue, which permission action is offered, whether a replacement can be saved after an error, which mode is selected, and whether an Esc event cancels or dismisses the correct presentation. They do not mirror private view structure or implementation counters.
- Use the existing `SpeakerAppScenarioSpecs` seam for composed permission, credential, onboarding, and Voice Input Session behavior with deterministic adapters. Existing provider-settings and permission-lifecycle scenarios provide prior art. Exercise the production trigger path through the real dispatcher and session coordinator with fake collaborators rather than testing an unrelated shortcut imitation.
- Use existing `SpeakerAppUISpecs` AppKit-hosted coverage for native keyboard focus, single-selection presentation, onboarding controls and accessibility, and HUD close controls. Native screenshot inspection supplements this seam for layout and clipping; a successful build alone is not visual acceptance.
- Reuse the existing Core specifications when testing session ownership, late events, User Cancellation, and credential-store failure boundaries. Keep the shared fake collaborators at their established interfaces; do not create a parallel test-only session model.
- Verify both provider cards through initial save, replacement, deletion cancellation, confirmed deletion, storage failure, connection failure, and replacement after failure. No live Key or billed provider request is required for these deterministic cases. Synthetic Keychain add/update checks, when run, must use temporary credential identities and leave no secrets in evidence.
- Verify that returning users can browse the reopened guide without a provider request, while first-time setup still enforces readiness and excludes credential mutation in progress.
- Verify permission state transitions for unrequested, denied, granted, and restricted states, including refresh after returning from System Settings and a revoked permission while a later setup step is displayed.
- Verify short recordings disappear without a notice, terminal notices dismiss through the actual Esc trigger path, idle Esc is not unnecessarily consumed, active-session Esc still cancels, and stale Esc cannot dismiss or cancel newer work.
- Verify DMG packaging with a signed fixture, a real read-only mount, unchanged executable and signature, Applications link, layout metadata, and installation instructions. Reject unsigned input and existing output. Run relevant workflow-security, release-identity, test-runner summary, and installer rollback contracts in addition to the normal deterministic gate.
- Run the relevant complete specification executables, formatting, warnings-as-errors builds, and full deterministic gate after implementation. Report those results separately from Finder inspection, synthetic credential-store checks, actual microphone capture, paid-provider acceptance, and other-machine testing.
- The proposed acceptance seams are the existing App Scenario and native AppKit UI executables, plus the packaging/mount contract for installation. No new product testing seam is required. The user requested local records only; no Linear specification or tickets are published.

## Out of Scope

- Recruiting more testers; the user already has a small beta group.
- Claiming acceptance for additional macOS releases, microphone hardware, target applications, or clean-machine permission flows without recorded tests in those environments.
- Establishing a production signing identity, paying for or provisioning distribution services, publishing a new release, or promoting an existing release.
- Replacing provider authentication, introducing a shared provider backend, bundling credentials, or changing billing policy.
- Automatically granting permissions, disabling system protections, or requesting Input Monitoring as another runtime permission.
- Redesigning Refinement Modes, provider routing, Input Target capture, text delivery, Personal Dictionary behavior, Session Record storage, or software-update semantics.
- Changing the recording-duration threshold or suppressing unrelated Session Problems.
- Resolving the broader quality/acceptance decision or the complete production-readiness matrix from this focused UX work alone.

## Further Notes

The seven reported feedback items are grouped into five independently verifiable delivery slices: DMG installation; provider credential recovery; three-step onboarding; Refinement Mode selection; and quiet short recordings with keyboard-dismissable, consistent floating notices. Only onboarding depends on the shared credential-recovery slice.

This specification records the requested final behavior. Implementation, deterministic checks, native visual checks, and tester acceptance must be reported as separate evidence. The presence of code or a passing local gate does not mark untested devices, macOS versions, live providers, or clean-machine installations as accepted.

Synthetic add and update checks against the local Keychain succeeded; the reported platform credential-replacement failure was not reproduced. The visible replacement and deletion flow is addressed, while real tester confirmation of the original report remains pending. This work does not claim a Keychain backend repair or prove live provider authentication.

Existing work on initial configuration and broader result handling remains related context. Publishing these records must not close or modify a parent decision or imply that broader scope is resolved.
