import Foundation

/// Every destination Speaker sends the user to outside its own windows.
///
/// A link literal appears here once, so a moved console page or repository is
/// corrected in one place, and no caller force-unwraps a URL.
package enum ExternalLinks {
    /// The Speaker source repository shown by the About page.
    package static let speakerRepository = absolute(
        "https://github.com/simonwong/speaker"
    )

    /// The Volcengine console page that issues Doubao speech API keys.
    package static let doubaoConsoleAPIKeys = absolute(
        "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default"
    )

    /// The DeepSeek platform page that issues refinement API keys.
    package static let deepSeekAPIKeys = absolute(
        "https://platform.deepseek.com/api_keys"
    )

    /// The privacy statement shipped inside the app bundle, absent in builds
    /// that do not carry the resource.
    package static var privacyPolicy: URL? {
        Bundle.main.url(
            forResource: "PRIVACY",
            withExtension: "md"
        )
    }

    /// Builds a compile-time-known destination. A malformed literal is a
    /// programming error, not a runtime condition callers can recover from.
    private static func absolute(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Speaker external link is not a valid URL")
        }
        return url
    }
}
