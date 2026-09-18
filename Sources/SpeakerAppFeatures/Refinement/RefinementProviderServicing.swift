import SpeakerCore

package protocol RefinementProviderServicing: Sendable {
    func hasAPIKey(for profile: RefinementProviderProfile) async throws -> Bool
    func saveAPIKey(_ apiKey: String, for profile: RefinementProviderProfile) async throws
    func deleteAPIKey(for provider: RefinementProviderID) async throws
    func checkConnection(profile: RefinementProviderProfile) async throws -> String?
}

extension CredentialedTextRefiner: RefinementProviderServicing {}
