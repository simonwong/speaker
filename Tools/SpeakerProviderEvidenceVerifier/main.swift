import Foundation
import SpeakerProviderEvidence

@main
private struct SpeakerProviderEvidenceVerifier {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var allowDevelopmentCredentials = false
        var releaseBinding: [String: String] = [:]
        let valueOptions: Set<String> = [
            "--expected-source-commit",
            "--expected-package-resolved-sha256",
            "--expected-version",
            "--expected-build",
            "--generated-not-before",
            "--generated-not-after",
        ]
        var path: String?
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            if argument == "--allow-development-credentials" {
                guard !allowDevelopmentCredentials else { usage() }
                allowDevelopmentCredentials = true
            } else if valueOptions.contains(argument) {
                guard releaseBinding[argument] == nil, !arguments.isEmpty else { usage() }
                releaseBinding[argument] = arguments.removeFirst()
            } else {
                guard path == nil else { usage() }
                path = argument
            }
        }
        guard let path else { usage() }
        let hasReleaseBinding = !releaseBinding.isEmpty
        guard !hasReleaseBinding || releaseBinding.count == valueOptions.count,
              !(allowDevelopmentCredentials && hasReleaseBinding)
        else {
            usage()
        }
        do {
            let data = try ProviderEvidenceFile.readSecurely(
                from: URL(fileURLWithPath: path)
            )
            let evidence = try ProviderMatrixEvidence.decodeStrict(data)
            if hasReleaseBinding {
                let formatter = ISO8601DateFormatter()
                guard let generatedNotBefore = formatter.date(
                    from: releaseBinding["--generated-not-before"]!
                ), let generatedNotAfter = formatter.date(
                    from: releaseBinding["--generated-not-after"]!
                ) else {
                    throw ProviderEvidenceError.invalidSchema("releaseTime")
                }
                try evidence.validateReleaseBinding(
                    sourceCommit: releaseBinding["--expected-source-commit"]!,
                    packageResolvedSHA256: releaseBinding[
                        "--expected-package-resolved-sha256"
                    ]!,
                    candidateVersion: releaseBinding["--expected-version"]!,
                    candidateBuild: releaseBinding["--expected-build"]!,
                    generatedNotBefore: generatedNotBefore,
                    generatedNotAfter: generatedNotAfter
                )
                print("PASS: provider evidence is bound to this release run")
            } else {
                try evidence.validate(
                    requirePassingCases: true,
                    requireSignedAppKeychain: !allowDevelopmentCredentials
                )
                print("PASS: provider evidence is complete and structurally valid")
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: provider evidence is incomplete or invalid\n".utf8))
            exit(1)
        }
    }

    private static func usage() -> Never {
        let message = """
        Usage: SpeakerProviderEvidenceVerifier [--allow-development-credentials] /path/to/speaker-provider-matrix.json
               SpeakerProviderEvidenceVerifier --expected-source-commit COMMIT --expected-package-resolved-sha256 SHA256 --expected-version VERSION --expected-build BUILD --generated-not-before ISO8601 --generated-not-after ISO8601 /path/to/speaker-provider-matrix.json
        """
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(64)
    }
}
