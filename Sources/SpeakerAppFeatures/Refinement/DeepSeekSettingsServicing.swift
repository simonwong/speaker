import Foundation
import SpeakerCore

/// The DeepSeek credential seam the refinement settings model depends on. It
/// carries only the credential and connection operations that model calls, so
/// a specification can substitute a fake without a network transport.
package protocol DeepSeekSettingsServicing: Sendable {
    func hasAPIKey() async throws -> Bool
    func saveAPIKey(_ apiKey: String) async throws
    func deleteAPIKey() async throws
    func checkConnection() async throws -> String?
}

extension CredentialedDeepSeekTextRefiner: DeepSeekSettingsServicing {}
