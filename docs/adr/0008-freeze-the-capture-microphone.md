# ADR-0008: Freeze the Capture Microphone for Each Voice Input Session

Status: Accepted

Date: 2026-09-12

A Microphone Preference follows the system input or identifies a particular microphone. Speaker resolves that preference against its latest observed device snapshot when the recording press enters the application and keeps the resulting input fixed for that Voice Input Session. The Input Target is still frozen separately when recording ends.

The shortcut callback does not perform CoreAudio I/O. A system change whose notification has not arrived may therefore appear on the next press; this is not an atomic read of the operating system's settings. Startup refreshes the directory and validates the frozen UID and device ID instead of silently resolving the plan again.

A missing or changed selected input stops capture instead of falling back to another microphone. Automatic fallback could record a source the user did not intend, and changing the input mid-session would mix devices and invalidate the existing converter. Changing the preference therefore affects the next session; reconnecting a device never resumes an interrupted session. The system-wide default input remains under the user's control.

Microphone identity is transient except for the selected UID in owner-only settings. Local level testing shares the capture lifecycle, produces no provider request or Session Record, and yields to normal voice input. Generation ownership prevents late device or preview callbacks from stopping a later capture.
