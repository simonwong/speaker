import Foundation

/// The directory name Speaker uses under Application Support, Caches, and
/// `~/Library`. Release bundles use "Speaker". Development bundles set
/// `SpeakerDataDirectoryName` in Info.plist so they never read or write the
/// data of the release installed on the same Mac.
public enum SpeakerDataDirectory {
    public static let infoKey = "SpeakerDataDirectoryName"
    public static let releaseName = "Speaker"

    /// The name declared by the running bundle, or the release name.
    public static var name: String { name(in: .main) }

    public static func name(in bundle: Bundle) -> String {
        name(declared: bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// A declared name is used only when it is a single path component.
    package static func name(declared: String?) -> String {
        guard let declared,
            !declared.isEmpty,
            declared != ".",
            declared != "..",
            !declared.contains("/"),
            !declared.contains(":")
        else { return releaseName }
        return declared
    }
}
