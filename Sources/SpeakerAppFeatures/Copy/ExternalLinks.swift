import Foundation

/// Every destination Speaker sends the user to outside its own windows.
///
/// A link literal appears here once, so a moved console page or repository is
/// corrected in one place, and no caller force-unwraps a URL.
package enum ExternalLinks {
    /// The Speaker website shown by the About page.
    package static let speakerWebsite = absolute(
        "https://speaker.moonunder.app"
    )

    /// The Speaker source repository shown by the About page.
    package static let speakerRepository = absolute(
        "https://github.com/simonwong/speaker"
    )

    /// Where users report problems and suggestions.
    package static let speakerIssues = absolute(
        "https://github.com/simonwong/speaker/issues"
    )

    /// The GitHub release page for a version; releases are tagged `v<version>`.
    /// A version outside the tag alphabet has no page.
    package static func releaseNotes(for version: String) -> URL? {
        let allowed = CharacterSet(
            charactersIn: "0123456789.-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !version.isEmpty,
            version.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return URL(string: "https://github.com/simonwong/speaker/releases/tag/v\(version)")
    }

    /// The author's GitHub profile shown by the About page.
    package static let authorProfile = absolute(
        "https://github.com/simonwong"
    )

    /// The Volcengine console page that issues Doubao speech API keys.
    package static let doubaoConsoleAPIKeys = absolute(
        "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default"
    )

    /// Speaker's walkthrough for getting a Doubao speech API Key and
    /// activating the matching streaming resource.
    package static let doubaoSetupGuide = absolute(
        "https://speaker.moonunder.app/doubao"
    )

    /// The DeepSeek platform page that issues refinement API keys.
    package static let deepSeekAPIKeys = absolute(
        "https://platform.deepseek.com/api_keys"
    )

    /// The OpenAI platform page that issues API keys for transcription and
    /// refinement.
    package static let openAIAPIKeys = absolute(
        "https://platform.openai.com/api-keys"
    )

    /// The Alibaba Cloud Model Studio pages that issue Qwen API keys. A Key
    /// works only in the region whose console issued it.
    package static let qwenBeijingAPIKeys = absolute(
        "https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key"
    )
    package static let qwenSingaporeAPIKeys = absolute(
        "https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key"
    )

    /// The Moonshot platform page that issues Kimi API keys.
    package static let kimiAPIKeys = absolute(
        "https://platform.kimi.com/console/api-keys"
    )

    /// The Zhipu platform page that issues GLM API keys.
    package static let glmAPIKeys = absolute(
        "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
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
