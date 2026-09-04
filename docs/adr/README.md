# Architecture Decision Records

ADRs preserve decisions whose rationale future architecture work must understand before proposing a different seam or module shape.

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-run-outside-app-sandbox.md) | Accepted | Run as a menu-bar Accessibility application outside App Sandbox |
| [0002](0002-freeze-the-input-target.md) | Accepted | Freeze the Input Target when recording ends and deliver fail closed |
| [0003](0003-stream-doubao-and-refine-optionally.md) | Accepted | Stream audio to Doubao and use DeepSeek only for optional text refinement |
| [0004](0004-protect-local-sensitive-data.md) | Accepted | Protect local sensitive data through owner-only persistence and explicit erasure |
| [0005](0005-deliver-updates-through-sparkle.md) | Accepted | Deliver updates through Sparkle with three independent verifications |
| [0006](0006-store-session-records-in-sqlite.md) | Accepted | Store Session Records in SQLite with WAL and explicit convergence |
| [0007](0007-specify-behavior-through-sequential-executables.md) | Accepted | Specify behavior through sequential `@main` executables instead of XCTest |

Create a new ADR when a load-bearing decision changes. Keep superseded ADRs as history and link the replacement rather than rewriting the old decision.
