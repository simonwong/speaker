# macOS Voice Input

Speaker is a personal macOS tool that starts voice input from a global shortcut and delivers the processed text to the work position selected when recording ends.

## Language

**Voice Input Session**

One attempt from shortcut activation through recording, transcription, optional refinement, and delivery or fallback. At most one session is active at a time.

_Avoid_: request, job, recording session

**Refinement Mode**

The text-processing strategy selected for a Voice Input Session. Each mode has a stable name and states how it may transform a transcript while preserving meaning.

_Avoid_: rule, transcription prompt

**Default Smoothing**

The built-in Refinement Mode that removes pauses, fillers, and repeated speech without deliberately reorganizing the content. It uses Doubao only.

_Avoid_: default rule, smart rewrite

**Custom Mode**

A user-named Refinement Mode with a user-authored refinement instruction.

_Avoid_: custom rule, custom transcription

**Personal Dictionary**

The local collection of canonical terms that belongs only to the current user and improves recognition consistency for names and specialist vocabulary.

_Avoid_: cloud dictionary, team dictionary

**Entry**

A canonical spelling, zero or more spoken aliases, and an enabled state. Disabling an Entry preserves it without applying it to new sessions.

_Avoid_: hotword, replacement rule

**Input Target**

The editable position focused when recording ends. Once captured, it is the Voice Input Session's only target; later window or focus changes never retarget the session.

_Avoid_: input focused when recording starts, current window

**Pending Copy Result**

A complete Voice Input Session result that could not be safely delivered to its Input Target and remains available for explicit user copy.

_Avoid_: failed text, lost result

**Session Record**

The local history record for a Voice Input Session. It may contain Stage Results, the Refinement Mode, target application, status, timing, and content-free diagnostics, but never raw audio.

_Avoid_: recording history, chat record

**Stage Result**

Text produced by transcription, smoothing, or further refinement within a Voice Input Session. The term distinguishes provider input, provider output, and the final delivered text.

_Avoid_: version, temporary text

**Waiting For Result**

A non-terminal state in which a Voice Input Session has entered external processing but has received neither a Stage Result nor an explicit Session Problem. Local elapsed time alone never changes this state into failure.

_Avoid_: timeout, stuck, processing failure

**Session Problem**

An explicit fact reported by the system, Input Target, or provider that prevents a Voice Input Session from continuing or delivering. It records the reporting party, stage, and safe diagnostic identifiers without inventing an unverified root cause.

_Avoid_: guessed cause, fallback error, generic failure

**User Cancellation**

The user's explicit termination of an unfinished Voice Input Session. User Cancellation is not a Session Problem. Late Stage Results are discarded, while the Session Record retains the stage at which cancellation occurred.

_Avoid_: processing failure, network interruption
