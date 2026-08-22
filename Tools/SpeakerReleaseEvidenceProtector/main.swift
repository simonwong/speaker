import CryptoKit
import Foundation

@main
private struct SpeakerReleaseEvidenceProtector {
    private static let header = Data("speaker-evidence-v1\n".utf8)
    private static let passwordName = "SPEAKER_EVIDENCE_ARCHIVE_PASSWORD"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            selfTest()
            return
        }
        guard arguments.count == 3,
              arguments[0] == "encrypt" || arguments[0] == "decrypt"
        else {
            usage()
        }
        do {
            let password = ProcessInfo.processInfo.environment[passwordName]
            let key = try encryptionKey(password: password)
            let inputURL = URL(fileURLWithPath: arguments[1])
            let outputURL = URL(fileURLWithPath: arguments[2])
            let input = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
            let output = try arguments[0] == "encrypt"
                ? encrypt(input, key: key)
                : decrypt(input, key: key)
            try output.write(to: outputURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
        } catch {
            FileHandle.standardError.write(
                Data("FAIL: release evidence protection failed\n".utf8)
            )
            exit(1)
        }
    }

    private static func encryptionKey(password: String?) throws -> SymmetricKey {
        guard let password, password.utf8.count >= 32 else {
            throw ProtectionError.invalidPassword
        }
        return SymmetricKey(data: SHA256.hash(data: Data(password.utf8)))
    }

    private static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealed = try ChaChaPoly.seal(data, using: key)
        return header + sealed.combined
    }

    private static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: header) else {
            throw ProtectionError.invalidArchive
        }
        let sealed = try ChaChaPoly.SealedBox(combined: data.dropFirst(header.count))
        return try ChaChaPoly.open(sealed, using: key)
    }

    private static func selfTest() {
        let key = try! encryptionKey(
            password: "speaker-release-evidence-self-test-0001"
        )
        let cleartext = Data("private release evidence".utf8)
        let protected = try! encrypt(cleartext, key: key)
        guard protected != cleartext,
              try! decrypt(protected, key: key) == cleartext
        else {
            exit(1)
        }
        var tampered = protected
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        guard (try? decrypt(tampered, key: key)) == nil else {
            exit(1)
        }
        print("PASS: release evidence encryption rejects tampering")
    }

    private static func usage() -> Never {
        FileHandle.standardError.write(
            Data("Usage: SpeakerReleaseEvidenceProtector encrypt|decrypt INPUT OUTPUT\n".utf8)
        )
        exit(64)
    }

    private enum ProtectionError: Error {
        case invalidArchive
        case invalidPassword
    }
}
