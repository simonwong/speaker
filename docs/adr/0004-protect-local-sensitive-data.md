# ADR-0004: Protect Local Sensitive Data Through Explicit Persistence

Status: Accepted

Date: 2026-07-18

## Context

Speaker stores Session Records, settings, a Personal Dictionary, provider credentials, and release diagnostics. These data have different representations but share filesystem risks: permissive modes, symbolic-link traversal, path replacement between validation and use, partial writes, unbounded input, and incomplete deletion.

Generic convenience persistence makes these guarantees easy to scatter across callers and difficult to verify through one interface.

## Decision

Provider credentials use Keychain. File-backed sensitive data cross the `OwnerOnlyFilePersistence` interface, which performs descriptor-relative, no-follow, owner-checked, size-bounded reads and atomic owner-only writes.

Session Records use versioned SQLite transactions with secure deletion behavior and explicit WAL convergence. Transcript text is persisted only after the Input Target's security class is confirmed; secure-target records never contain text or provider request identifiers.

Raw audio is bounded in memory and is never a normal persisted artifact. Diagnostics exclude audio, transcript text, provider free-form messages, AX objects, clipboard contents, and credential values.

Local data erasure is one deep operation. It fences new writes, disables login launch, removes credentials and owned data, verifies the result, records recoverable partial progress, and exits only after successful convergence.

## Consequences

- New sensitive file I/O must reuse the owner-only persistence module instead of duplicating path checks.
- A protection failure is a data-boundary failure, not corrupted-content recovery; unsafe input remains untouched for diagnosis.
- Persistence and erasure tests cross the same interfaces as production callers with temporary and in-memory adapters.
- Recovery archives, retention, migration, and deletion must preserve physical as well as logical privacy guarantees.
