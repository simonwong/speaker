/// Whether the selected Speech Recognition Provider can serve the next Voice
/// Input Session, as far as Settings knows before any recording.
///
/// `SpeechRecognitionSettingsModel` derives it once. The menu bar, the
/// Overview banner, onboarding, and the diagnostic report all read this one
/// value; they differ only in which cases they accept.
package enum SpeechRecognitionReadiness: String, Equatable, Sendable {
    /// The Key or language model has not been read yet, so nothing is
    /// reported while Speaker launches.
    case unread
    /// No saved Key, no installed language model, or a saved profile Speaker
    /// cannot run.
    case needsSetup
    /// A Key is saved, but the provider offers a connection check that has
    /// not succeeded for this Key and its current settings. Only Doubao
    /// offers one, because its Key works only with an activated resource.
    case unverified
    case ready

    /// A Key is saved or the language model is installed. The session itself
    /// reports a Key the provider rejects, so an unchecked Key is no setup gap.
    package var isConfigured: Bool {
        self == .unverified || self == .ready
    }
}
