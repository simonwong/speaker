# macOS Voice Input

Speaker is a personal macOS tool that starts voice input from a global shortcut and delivers the processed text to the work position selected when recording ends.

## Language

**Voice Input Session**

One attempt from shortcut activation through recording, transcription, optional refinement, and delivery or fallback. At most one session is active at a time.

_Avoid_: request, job, recording session

**Microphone Preference**

The user's choice to follow the system input or use one particular microphone. It selects the microphone for the next Voice Input Session; changing it does not retarget a session already recording.

_Avoid_: system default override, active microphone

**Refinement Mode**

The text-processing strategy selected for a Voice Input Session. Each mode has a stable name and states how it may transform a transcript while preserving meaning.

_Avoid_: rule, transcription prompt

**Refinement Provider**

The user-selected service and model that may refine a confirmed recognition Stage Result. Its destination and credential ownership are fixed for each Voice Input Session; it never receives audio.

_Avoid_: transcription provider, model router

**Speech Recognition Provider**

The user-selected service and model that turns a Voice Input Session's audio into a Stage Result. Its destination and credential ownership are fixed for that session, independently of the Refinement Provider.

_Avoid_: audio refinement provider, automatic model router

**Default Smoothing**

The built-in Refinement Mode that uses the Speech Recognition Provider's confirmed text without a separate refinement request. Its cleanup depends on that provider's recognition capabilities.

_Avoid_: default rule, smart rewrite

**Custom Mode**

A user-named Refinement Mode with a user-authored refinement instruction.

_Avoid_: custom rule, custom transcription

**Personal Dictionary**

The local collection of user-supplied terms that belongs only to the current user and improves recognition accuracy for names and specialist vocabulary.

_Avoid_: cloud dictionary, team dictionary

**Entry**

A single user-supplied spelling sent with a Voice Input Session to improve its recognition accuracy. Removing an Entry stops applying it to new sessions.

_Avoid_: hotword, alias mapping, replacement rule, disabled entry

**Input Target**

The editable position focused when recording ends. Once captured, it is the Voice Input Session's only target; later window or focus changes never retarget the session.

_Avoid_: input focused when recording starts, current window

**Pending Copy Result**

A complete Voice Input Session result that could not be safely delivered to its Input Target and remains available for explicit user copy.

_Avoid_: failed text, lost result

**Session Record**

The local history record for a Voice Input Session. It may contain Stage Results, the Speech Recognition Provider, the Refinement Mode and Refinement Provider, status, provider request identifiers, structured failure codes, the Personal Dictionary snapshot, timing, and content-free diagnostics, but never raw audio, target-application identity, or free-text provider messages.

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
