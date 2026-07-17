import Foundation
import SpeakerProviderEvidence

@main
private struct SpeakerProviderEvidenceVerifier {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var allowDevelopmentCredentials = false
        if arguments.first == "--allow-development-credentials" {
            allowDevelopmentCredentials = true
            arguments.removeFirst()
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("Usage: SpeakerProviderEvidenceVerifier [--allow-development-credentials] /path/to/speaker-provider-matrix.json\n".utf8))
            exit(64)
        }
        do {
            let data = try ProviderEvidenceFile.readSecurely(
                from: URL(fileURLWithPath: arguments[0])
            )
            let evidence = try ProviderMatrixEvidence.decodeStrict(data)
            try evidence.validate(
                requirePassingCases: true,
                requireSignedAppKeychain: !allowDevelopmentCredentials
            )
            print("PASS: provider evidence is complete and structurally valid")
        } catch {
            FileHandle.standardError.write(Data("FAIL: provider evidence is incomplete or invalid\n".utf8))
            exit(1)
        }
    }
}
