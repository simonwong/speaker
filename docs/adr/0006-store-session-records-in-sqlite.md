# ADR-0006: Store Session Records in SQLite With WAL and Explicit Convergence

Status: Accepted

Date: 2026-09-04

## Context

A Session Record may hold Stage Results, the Refinement Mode, timing, delivery status, and content-free diagnostics. History is searched, inspected, deleted, cleared, aggregated into usage totals, and evicted by a retention policy. That makes it the largest and longest-lived body of sensitive local data Speaker keeps.

The first implementation, `VersionedLocalSessionHistory`, rewrote one versioned JSON document. Every save serialized the whole history, so cost grew with the archive; a delete only removed a logical entry while the previous bytes stayed in whatever the filesystem last wrote; and there was no transaction boundary, so an interrupted write could not distinguish a committed change from a partial one. Deleting a Session Record has to be a privacy operation, not a display filter, and a document rewrite cannot promise that.

## Decision

Session Records live in SQLite through `SQLiteSessionHistory`, an actor in `SpeakerCore`. The file crosses `OwnerOnlyFilePersistence` ([ADR-0004](0004-protect-local-sensitive-data.md)), and the database, `-wal`, `-shm`, and `-journal` companions are re-protected after every write.

`VersionedLocalSessionHistory` is kept only as a legacy source. `SpeakerRuntime` reads it once at startup, imports its records through `importLegacyRecords`, and removes the old document only after the import verifies. A legacy file that reports corruption, a permission problem, or a write failure is left untouched and reported as a diagnostic. The migration is one-way; nothing writes the JSON document again.

The connection opens with `journal_mode=WAL`, `synchronous=FULL`, and `secure_delete=ON`. WAL keeps readers off the writer's path; `secure_delete` overwrites freed pages so removed content does not survive in the file. Every mutation runs as `BEGIN IMMEDIATE` and either commits or rolls back.

Retention eviction is a destructive transaction, not a filter. `SessionHistoryRecordPolicy` and the store's `prune` apply the user's age policy and the hard record cap inside the same transaction as the write that triggered them, and a destructive result marks a pending truncating checkpoint. A user-initiated clear additionally runs `VACUUM` between truncating checkpoints so the sidecar keeps no stale pages.

A busy checkpoint never presents a committed deletion as rolled back. `applyRetentionPolicy` stores the user's policy before attempting cleanup, because the policy is user intent and governs every later save; the transaction may already have committed when `sqlite3_wal_checkpoint_v2(SQLITE_CHECKPOINT_TRUNCATE)` reports the log still in use, and claiming a rollback would contradict rows that are already gone. Instead the pending-checkpoint flag survives, later writes retry the truncation, and every clean open reconciles the gap before the store is used — the case where a process died after committing but before truncating.

Privacy scrub is a migration with the same shape. `scrubUntrustedProviderMessages` removes free-form provider response text written by older builds, records a completed scrub version in the store's metadata table, and forces physical sanitization — checkpoint, `VACUUM`, checkpoint — whenever the plan changes rows or the recorded scrub version is behind. It then re-reads the store to verify no scrubbable content remains. A failure is reported as a privacy-migration failure and retried, never silently accepted.

Corruption is preserved, not repaired. An open that fails `quick_check` or reports a recoverable corruption class moves the whole file set into an owner-only `history.corrupt-<timestamp>-<uuid>` directory, opens a fresh database, and surfaces `corruptedDataPreserved` with the backup location. If any file cannot be moved, the partial move is restored and the recovery directory is kept, because deleting it could destroy the user's only remaining copy. Rows whose payload schema is unknown or undecodable are counted and skipped rather than rewritten.

Transcript text is persisted only after the Input Target's security class is confirmed. A secure target's Session Record holds no Stage Result text and no provider request identifiers in any state, including non-terminal and cancelled ones.

## Consequences

- History is transactional and incrementally written; save cost no longer scales with the size of the archive.
- A committed deletion is final. Callers observe eviction, clear, and scrub through the store's status and notice, never by inferring rollback from a checkpoint error.
- Checkpoint convergence is part of the store's contract: pending truncation must be retried on later writes and at the next clean open, and shutdown or erasure closes the database only after a successful checkpoint.
- Recovery artifacts and legacy documents are Speaker-owned files with their own privacy rules; a clear removes them, and pruning bounds how many corruption archives accumulate.
- Persistence specifications exercise temporary on-disk databases through the same interface as production callers, covering schema handling, retention, deletion, secure-target redaction, scrub, and corruption recovery.
- Replacing the storage engine again would have to reproduce transactional eviction, physical deletion, checkpoint convergence, and corruption preservation; it is not an implementation detail behind the history interface.
