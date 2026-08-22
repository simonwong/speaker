import CryptoKit
import Foundation

@main
private struct SpeakerUpdateSignatureVerifier {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            selfTest()
            return
        }
        guard arguments.count == 3 else { usage() }
        do {
            let file = URL(fileURLWithPath: arguments[0])
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard let signature = Data(base64Encoded: arguments[1]),
                  let publicKeyData = Data(base64Encoded: arguments[2]),
                  signature.count == 64,
                  publicKeyData.count == 32
            else {
                throw VerificationError.invalidEncoding
            }
            let publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
            )
            guard publicKey.isValidSignature(signature, for: data) else {
                throw VerificationError.invalidSignature
            }
            print("PASS: Sparkle archive Ed25519 signature is valid")
        } catch {
            FileHandle.standardError.write(
                Data("FAIL: Sparkle archive Ed25519 signature is invalid\n".utf8)
            )
            exit(1)
        }
    }

    private static func selfTest() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("Speaker signed update".utf8)
        let signature = try! privateKey.signature(for: payload)
        guard privateKey.publicKey.isValidSignature(signature, for: payload),
              !privateKey.publicKey.isValidSignature(
                  signature,
                  for: payload + Data("tampered".utf8)
              )
        else {
            exit(1)
        }
        print("PASS: public Ed25519 verifier rejects tampering")
    }

    private static func usage() -> Never {
        FileHandle.standardError.write(
            Data("Usage: SpeakerUpdateSignatureVerifier FILE SIGNATURE_BASE64 PUBLIC_KEY_BASE64\n".utf8)
        )
        exit(64)
    }

    private enum VerificationError: Error {
        case invalidEncoding
        case invalidSignature
    }
}
