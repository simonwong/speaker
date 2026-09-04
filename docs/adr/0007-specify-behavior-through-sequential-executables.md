# ADR-0007: Specify Behavior Through Sequential `@main` Executables Instead of XCTest

Status: Accepted

Date: 2026-09-04

## Context

Almost every load-bearing rule in Speaker is about ordering: a Voice Input Session is one ordered actor, the Input Target is frozen at a single instant, `DeliveryCommitGate` commits once, shutdown fences trigger intake before waiting on persistence, and history convergence happens at defined points. Verifying those rules requires controlling the order in which cases run and observing an actor from a single place.

XCTest gives no ordering guarantee across cases, runs them concurrently by default on a shared host, and needs a test bundle plus a host process. For a `MainActor` menu-bar application with AppKit windows, event taps, and an ordered session actor, that combination turns ordering bugs into flakiness and makes a failure hard to reproduce with one command. XCTest results also live in a bundle format rather than in something a reader can run and read top to bottom.

## Decision

Every suite is a plain SwiftPM executable target with an `@main` entry point that runs its cases sequentially on the `MainActor` and exits non-zero on failure: `SpeakerCoreSpecs`, `SpeakerAppScenarioSpecs`, `SpeakerAppUISpecs`, `SpeakerProviderEvidenceSpecs`, and `SpeakerAccuracyMetricsSpecs`. There is no XCTest dependency and no test bundle.

This buys four things:

- **Determinism.** One process, one ordered sequence, one `MainActor`. A failure reproduces from the same command.
- **No test-bundle host.** AppKit and actor-driven suites run as ordinary programs, so there is no host application whose lifecycle competes with the code under test.
- **Identical local and CI behavior.** `./scripts/swiftw run --disable-sandbox <product>` is what a developer runs and what `./scripts/test` runs; there is no separate `swift test` topology to diverge.
- **Executable documentation.** Case names are sentences describing product behavior, so a suite reads as a specification and every claim in it is enforced.

`SpeakerSpecSupport` is the shared harness library, and no executable redefines its parts:

- `run(_:failures:body:)` and `runAsync(_:failures:body:)` run one case, recording a failure instead of aborting the process, so one broken case does not hide the rest.
- `expect(_:_:)` throws a `SpecFailure` when a condition does not hold; `expectThrows(_:_:_:)` requires a specific error type and lets any other error propagate unchanged, so an unexpected failure is never mistaken for the expected one.
- `eventually(before:pollEvery:condition:)` polls until a condition holds or a deadline passes, which is the supported way to wait instead of sleeping before an assertion.
- `SpecSelection` reads a case-name filter from the command line: the remaining arguments are joined and matched case-insensitively against case names, so `swift run SpeakerCoreSpecs input target is frozen` runs only the matching cases.
- `SpecSummary.finish(failures:label:)` prints the outcome, exits `1` on any failure, and exits `2` when a filter matched no case at all — so a typo in a filter can never be read as a pass.

The specification seams themselves follow the architecture rule: a seam exists only where both a live and a deterministic adapter cross it, and the executables use the deterministic side. Command details are owned by [`docs/agents/development.md`](../agents/development.md); the behavior being specified is owned by [`docs/specs/voice-input.md`](../specs/voice-input.md).

Adding a case means adding one `run` or `await runAsync` block, with a descriptive name, inside the suite's `main`, before its `SpecSummary.finish` call, keeping any helper types local to the case. Iterate with a name filter, then run the whole executable, then `./scripts/test`.

## Consequences

- XCTest tooling is unavailable: no Xcode test navigator, no `swift test`, no XCTest parallelization, no test plans, no `XCTestExpectation`.
- There is no built-in code coverage. Coverage is judged by whether each product rule has a named case crossing the same interface production uses, not by a percentage.
- Cases are isolated by convention rather than by a framework. Each case must build its own state — temporary directories, fresh stores, fresh coordinators — because nothing resets shared state between cases in one process.
- Because the process is sequential, a case that hangs blocks the suite; waits go through `eventually` with a bounded deadline rather than an unbounded sleep or await.
- Suites grow long as single files. That is accepted in exchange for a readable top-to-bottom specification and one reproducible command per suite.
- Adopting XCTest or Swift Testing later would mean re-establishing ordering guarantees, the filter contract, and the exit-status contract that `./scripts/test` depends on; it requires a new ADR.
