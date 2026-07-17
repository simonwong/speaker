import Darwin
import Foundation
import SpeakerProviderEvidence

private enum SpecFailure: Error {
    case failed(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SpecFailure.failed(message) }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw SpecFailure.failed(message)
    } catch is ProviderEvidenceError {
        return
    }
}

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
    static func main() throws {
        let valid = evidence()
        try valid.validate(requirePassingCases: true, requireSignedAppKeychain: false)
        try expectThrows("release verification accepted development credentials") {
            try valid.validate(requirePassingCases: true, requireSignedAppKeychain: true)
        }
        try evidence(credentialSource: .signedAppKeychain).validate(
            requirePassingCases: true,
            requireSignedAppKeychain: true
        )
        let releaseGeneratedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let releaseEvidence = evidence(
            credentialSource: .signedAppKeychain,
            generatedAt: releaseGeneratedAt
        )
        try releaseEvidence.validateReleaseBinding(
            sourceCommit: String(repeating: "a", count: 40),
            packageResolvedSHA256: String(repeating: "b", count: 64),
            candidateVersion: "1.2.3",
            candidateBuild: "42",
            generatedNotBefore: releaseGeneratedAt.addingTimeInterval(-1),
            generatedNotAfter: releaseGeneratedAt.addingTimeInterval(1)
        )
        try expectThrows("stale release evidence passed") {
            try releaseEvidence.validateReleaseBinding(
                sourceCommit: String(repeating: "a", count: 40),
                packageResolvedSHA256: String(repeating: "b", count: 64),
                candidateVersion: "1.2.3",
                candidateBuild: "42",
                generatedNotBefore: releaseGeneratedAt.addingTimeInterval(1),
                generatedNotAfter: releaseGeneratedAt.addingTimeInterval(2)
            )
        }
        try expectThrows("evidence for another commit passed") {
            try releaseEvidence.validateReleaseBinding(
                sourceCommit: String(repeating: "c", count: 40),
                packageResolvedSHA256: String(repeating: "b", count: 64),
                candidateVersion: "1.2.3",
                candidateBuild: "42",
                generatedNotBefore: releaseGeneratedAt.addingTimeInterval(-1),
                generatedNotAfter: releaseGeneratedAt.addingTimeInterval(1)
            )
        }
        try expectThrows("dirty source tree passed") {
            try evidence(sourceTreeClean: false).validate(
                requirePassingCases: true,
                requireSignedAppKeychain: false
            )
        }
        try expectThrows("missing case passed") {
            try evidence(results: Array(cases().dropLast())).validate(
                requirePassingCases: true,
                requireSignedAppKeychain: false
            )
        }
        var duplicate = cases()
        duplicate[duplicate.count - 1] = duplicate[0]
        try expectThrows("duplicate case passed") {
            try evidence(results: duplicate).validate(
                requirePassingCases: true,
                requireSignedAppKeychain: false
            )
        }
        try expectThrows("SKIP passed") {
            try evidence(results: cases(status: .skip)).validate(
                requirePassingCases: true,
                requireSignedAppKeychain: false
            )
        }

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

        let encoded = try valid.encoded()
        let encodedText = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["apiKey", "transcript", "providerMessage", "secret body"] {
            try expect(!encodedText.contains(forbidden), "report contains forbidden field")
        }
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["providerMessage"] = "do not accept"
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        try expectThrows("unknown JSON field passed") {
            _ = try ProviderMatrixEvidence.decodeStrict(unknownField)
        }

        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("speaker-provider-evidence-spec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = try ProviderEvidenceFile.writeAtomically(valid, toNewDirectory: root)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber).intValue
        let reportMode = (try FileManager.default.attributesOfItem(atPath: reportURL.path)[.posixPermissions] as! NSNumber).intValue
        try expect(directoryMode == 0o700, "evidence directory is not 0700")
        try expect(reportMode == 0o600, "evidence report is not 0600")
        _ = try ProviderMatrixEvidence.decodeStrict(
            ProviderEvidenceFile.readSecurely(from: reportURL)
        )
        try expectThrows("existing evidence directory was reused") {
            _ = try ProviderEvidenceFile.writeAtomically(valid, toNewDirectory: root)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: reportURL.path)
        try expectThrows("wide report permissions passed") {
            _ = try ProviderEvidenceFile.readSecurely(from: reportURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        let symlinkURL = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: reportURL)
        try expectThrows("symlink report passed") {
            _ = try ProviderEvidenceFile.readSecurely(from: symlinkURL)
        }

        let parentFixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("speaker-provider-parent-spec-\(UUID().uuidString)")
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
        try expectThrows("symlink ancestor was followed while writing") {
            _ = try ProviderEvidenceFile.writeAtomically(
                valid,
                toNewDirectory: linkedParent.appendingPathComponent("evidence")
            )
        }

        print("PASS: provider evidence schema, privacy, completeness, and filesystem specs")
    }
}
