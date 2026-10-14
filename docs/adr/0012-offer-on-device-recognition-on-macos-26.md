# ADR-0012: Offer Apple on-device recognition on macOS 26 and later

Status: Accepted

Date: 2026-10-14

Speaker adds Apple's on-device recognition as a fourth Speech Recognition Provider, `apple`. It uses `SpeechAnalyzer` with `SpeechTranscriber`, which exist only on macOS 26 and later. The deployment target stays macOS 14. On earlier releases, and on a Mac where `SpeechTranscriber.isAvailable` is false, Settings and onboarding do not list the provider at all; it is hidden, not disabled. A settings file that selects it on such a Mac falls back to the last cloud provider.

The provider needs no Key and sends no audio off the Mac. Its one setup requirement is the system language model for the recognition locale, which is the first entry in the user's preferred languages that `SpeechTranscriber` supports, else `zh-CN`. A cloud provider's Key is replaced by an installed model as the readiness condition in onboarding, the setup gap, and diagnostics. Speaker downloads the model only when the user clicks the download control, through `AssetInventory`.

Recognition follows the streaming method's contract: captured 16 kHz Int16 mono PCM is passed to the analyzer during recording, and the `AudioCaptureCompletionGate` must accept before `finalizeAndFinishThroughEndOfInput` runs. Only the finalized text reaches the session; cancellation cancels the analyzer and discards its results. There is no automatic fallback to a cloud provider when on-device recognition fails.

`SpeechTranscriber` was chosen over `DictationTranscriber` after comparing both on the same Mandarin-English recordings. `DictationTranscriber` produced better punctuation and numbers but worse English terms ("M分之" for "main分支"), and it returned no finalized result. `SpeechTranscriber` separates Latin text and digits from Chinese with spaces, so the adapter removes spaces next to CJK characters. Contextual strings had no measurable effect on `SpeechTranscriber`, so the Personal Dictionary is not sent to it; a non-default Refinement Mode still receives the Entry words.

Older builds decode `selectedProvider` as a closed enum and treat an unknown value as corrupted settings. On-device selection is therefore stored in a separate `onDeviceProvider` key, `selectedProvider` keeps the last cloud provider, and on-device profiles are never written to `profiles`. A downgraded build reads the cloud provider and ignores the new key.
