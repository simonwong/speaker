# ADR-0001: Run Outside App Sandbox

Status: Accepted

Date: 2026-07-18

## Context

Speaker must observe a global `Fn` gesture, register custom shortcuts, inspect the focused editable Accessibility element in another application, and deliver text back to that element. It also runs without a Dock presence and presents non-activating status surfaces.

App Sandbox does not provide the required assistive-application access. Treating cross-application delivery as optional would remove the product's core behavior, while adding a helper process would move the same trust and distribution problem into another executable without creating useful depth.

## Decision

Speaker is a menu-bar application distributed outside the Mac App Store and runs without App Sandbox.

Voice input requests Accessibility and Microphone permission. Accessibility covers cross-application inspection and event behavior; Speaker does not add Input Monitoring as a second permission for the same capability.

The application uses stable Developer ID signing, Hardened Runtime, notarization, and a signed update channel for production distribution. Development builds remain clearly distinguished from production identity.

## Consequences

- Mac App Store distribution is not a supported path.
- Signing identity is part of permission continuity, so release validation must include TCC behavior across upgrades.
- Onboarding must explain why Accessibility is required before requesting it.
- Platform adapters stay behind deterministic seams so most product behavior remains testable without live permissions.
- A future sandboxed edition would be a different product contract and requires a new ADR rather than a build-setting toggle.
