import Foundation

package enum DoubaoConnectionStatus: Equatable, Sendable {
    case loading
    case unconfigured
    case configured
    case checking
    case success(String?)
    case failure(String)

    package func afterCredentialRefresh(keyExists: Bool) -> Self {
        guard keyExists else { return .unconfigured }
        return switch self {
        case .checking, .success:
            self
        case .loading, .unconfigured, .configured, .failure:
            .configured
        }
    }
}
