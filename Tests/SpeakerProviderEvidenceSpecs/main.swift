import Darwin
import Foundation
import SpeakerProviderEvidence
import SpeakerSpecSupport

private func cases(status: EvidenceStatus = .pass) -> [ProviderEvidenceCase] {
    ProviderMatrixCaseID.allCases.map { caseID in
        let outcome: EvidenceOutcome
        if status == .skip {
            outcome = .notConfigured
        } else if status == .fail {
            outcome = .unexpected
        } else if caseID == .doubaoCancelStreaming || caseID == .deepSeekCancelInFlight {
            outcome = .cancelled
        } else if caseID == .doubaoInvalidCredential {
            outcome = .invalidCredential
        } else if caseID == .deepSeekInvalidCredential {
            outcome = .authentication
        } else {
            outcome = .passed
        }
        return ProviderEvidenceCase(
            provider: caseID.provider,
            caseID: caseID,
            status: status,
            outcome: outcome,
            providerStatusCode: "200",
            requestID: "request_123"
        )
    }
}

private func evidence(
    sourceTreeClean: Bool = true,
    credentialSource: EvidenceCredentialSource = .developmentOwnerOnlyFile,
    results: [ProviderEvidenceCase] = cases(),
    generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ProviderMatrixEvidence {
    ProviderMatrixEvidence(
        generatedAt: generatedAt,
        environment: ProviderEvidenceEnvironment(
            sourceCommit: String(repeating: "a", count: 40),
            sourceTreeClean: sourceTreeClean,
            packageResolvedSHA256: String(repeating: "b", count: 64),
            candidateVersion: "1.2.3",
            candidateBuild: "42",
            macOSVersion: "15.5",
            architecture: "arm64"
        ),
        providers: [
            ProviderEvidenceConfiguration(
                provider: .doubao,
                credentialSource: credentialSource,
                resource: "volc.seedasr.sauc.duration",
                model: "bigmodel"
            ),
            ProviderEvidenceConfiguration(
                provider: .deepSeek,
                credentialSource: credentialSource,
                resource: nil,
                model: "deepseek-v4-flash"
            ),
        ],
        cases: results
    )
}

@main
private struct SpeakerProviderEvidenceSpecs {
    @MainActor
    static func main() {
        var failures: [String] = []
        let valid = evidence()
        let releaseGeneratedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let releaseEvidence = evidence(
            credentialSource: .signedAppKeychain,
            generatedAt: releaseGeneratedAt
        )

        run("development evidence validates without a signed-app keychain", failures: &failures) {
            try valid.validate(requirePassingCases: true, requireSignedAppKeychain: false)
        }

        run("release verification rejects development credentials", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "release verification accepted development credentials") {
                try valid.validate(requirePassingCases: true, requireSignedAppKeychain: true)
            }
        }

        run("signed-app keychain evidence validates for release", failures: &failures) {
            try evidence(credentialSource: .signedAppKeychain).validate(
                requirePassingCases: true,
                requireSignedAppKeychain: true
            )
        }

        run("release binding accepts matching commit, package hash, version, build, and window", failures: &failures) {
            try releaseEvidence.validateReleaseBinding(
                sourceCommit: String(repeating: "a", count: 40),
                packageResolvedSHA256: String(repeating: "b", count: 64),
                candidateVersion: "1.2.3",
                candidateBuild: "42",
                generatedNotBefore: releaseGeneratedAt.addingTimeInterval(-1),
                generatedNotAfter: releaseGeneratedAt.addingTimeInterval(1)
            )
        }

        run("release binding rejects stale evidence", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "stale release evidence passed") {
                try releaseEvidence.validateReleaseBinding(
                    sourceCommit: String(repeating: "a", count: 40),
                    packageResolvedSHA256: String(repeating: "b", count: 64),
                    candidateVersion: "1.2.3",
                    candidateBuild: "42",
                    generatedNotBefore: releaseGeneratedAt.addingTimeInterval(1),
                    generatedNotAfter: releaseGeneratedAt.addingTimeInterval(2)
                )
            }
        }

        run("release binding rejects evidence for another commit", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "evidence for another commit passed") {
                try releaseEvidence.validateReleaseBinding(
                    sourceCommit: String(repeating: "c", count: 40),
                    packageResolvedSHA256: String(repeating: "b", count: 64),
                    candidateVersion: "1.2.3",
                    candidateBuild: "42",
                    generatedNotBefore: releaseGeneratedAt.addingTimeInterval(-1),
                    generatedNotAfter: releaseGeneratedAt.addingTimeInterval(1)
                )
            }
        }

        run("dirty source tree is rejected", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "dirty source tree passed") {
                try evidence(sourceTreeClean: false).validate(
                    requirePassingCases: true,
                    requireSignedAppKeychain: false
                )
            }
        }

        run("missing matrix case is rejected", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "missing case passed") {
                try evidence(results: Array(cases().dropLast())).validate(
                    requirePassingCases: true,
                    requireSignedAppKeychain: false
                )
            }
        }

        run("duplicate matrix case is rejected", failures: &failures) {
            var duplicate = cases()
            duplicate[duplicate.count - 1] = duplicate[0]
            try expectThrows(ProviderEvidenceError.self, "duplicate case passed") {
                try evidence(results: duplicate).validate(
                    requirePassingCases: true,
                    requireSignedAppKeychain: false
                )
            }
        }

        run("SKIP status is rejected when passing cases are required", failures: &failures) {
            try expectThrows(ProviderEvidenceError.self, "SKIP passed") {
                try evidence(results: cases(status: .skip)).validate(
                    requirePassingCases: true,
                    requireSignedAppKeychain: false
                )
            }
        }

        run("unsafe provider status and request ID never enter a case or its summary", failures: &failures) {
            let unsafe = ProviderEvidenceCase(
                provider: .doubao,
                caseID: .doubaoConnection,
                status: .pass,
                outcome: .passed,
                providerStatusCode: "secret body: denied",
                requestID: "key sentry/unsafe"
            )
            try expect(unsafe.providerStatusCode == nil, "unsafe status was retained")
            try expect(unsafe.requestID == nil, "unsafe request ID was retained")
            try expect(!unsafe.privacySafeSummary.contains("secret body"), "stdout retained provider body")
            try expect(!unsafe.privacySafeSummary.contains("sentry"), "stdout retained unsafe request ID")
        }

        run("encoded report has no forbidden fields and strict decoding rejects unknown fields", failures: &failures) {
            let encoded = try valid.encoded()
            let encodedText = String(decoding: encoded, as: UTF8.self)
            for forbidden in ["apiKey", "transcript", "providerMessage", "secret body"] {
                try expect(!encodedText.contains(forbidden), "report contains forbidden field")
            }
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["providerMessage"] = "do not accept"
            let unknownField = try JSONSerialization.data(withJSONObject: object)
            try expectThrows(ProviderEvidenceError.self, "unknown JSON field passed") {
                _ = try ProviderMatrixEvidence.decodeStrict(unknownField)
            }
        }

        run("evidence file is written owner-only into a fresh directory and read back strictly", failures: &failures) {
            let root = freshFixtureRoot("speaker-provider-evidence-spec")
            defer { try? FileManager.default.removeItem(at: root) }
            let reportURL = try ProviderEvidenceFile.writeAtomically(valid, toNewDirectory: root)
            let directoryMode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber).intValue
            let reportMode = (try FileManager.default.attributesOfItem(atPath: reportURL.path)[.posixPermissions] as! NSNumber).intValue
            try expect(directoryMode == 0o700, "evidence directory is not 0700")
            try expect(reportMode == 0o600, "evidence report is not 0600")
            _ = try ProviderMatrixEvidence.decodeStrict(
                ProviderEvidenceFile.readSecurely(from: reportURL)
            )
            try expectThrows(ProviderEvidenceError.self, "existing evidence directory was reused") {
                _ = try ProviderEvidenceFile.writeAtomically(valid, toNewDirectory: root)
            }
        }

        run("evidence read rejects wide permissions and symlinked reports", failures: &failures) {
            let root = freshFixtureRoot("speaker-provider-evidence-read-spec")
            defer { try? FileManager.default.removeItem(at: root) }
            let reportURL = try ProviderEvidenceFile.writeAtomically(valid, toNewDirectory: root)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: reportURL.path)
            try expectThrows(ProviderEvidenceError.self, "wide report permissions passed") {
                _ = try ProviderEvidenceFile.readSecurely(from: reportURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
            let symlinkURL = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: reportURL)
            try expectThrows(ProviderEvidenceError.self, "symlink report passed") {
                _ = try ProviderEvidenceFile.readSecurely(from: symlinkURL)
            }
        }

        run("evidence write refuses a symlinked ancestor directory", failures: &failures) {
            let parentFixture = freshFixtureRoot("speaker-provider-parent-spec")
            defer { try? FileManager.default.removeItem(at: parentFixture) }
            let realParent = parentFixture.appendingPathComponent("real")
            let linkedParent = parentFixture.appendingPathComponent("linked")
            try FileManager.default.createDirectory(
                at: realParent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createSymbolicLink(
                at: linkedParent,
                withDestinationURL: realParent
            )
            try expectThrows(ProviderEvidenceError.self, "symlink ancestor was followed while writing") {
                _ = try ProviderEvidenceFile.writeAtomically(
                    valid,
                    toNewDirectory: linkedParent.appendingPathComponent("evidence")
                )
            }
        }

        SpecSummary.finish(failures: failures, label: "provider evidence specs")
    }
}

private func freshFixtureRoot(_ prefix: String) -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}
