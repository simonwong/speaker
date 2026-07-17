import AppKit
import Foundation
import ServiceManagement
import SpeakerAppFeatures
import SpeakerCore

actor SpeakerProviderCredentialEraser {
    private let localFileURL: URL
    private let keychainServices: [String]

    init(
        localFileURL: URL = LocalFileProviderCredentialStore.defaultFileURL(),
        currentKeychainService: String?
    ) {
        self.localFileURL = localFileURL
        var services = [KeychainProviderCredentialStore.defaultService]
        if let currentKeychainService,
           !currentKeychainService.isEmpty,
           !services.contains(currentKeychainService) {
            services.append(currentKeychainService)
        }
        keychainServices = services
    }

    func erase() async throws {
        try removeLocalCredentialFile()
        for service in keychainServices {
            let store = KeychainProviderCredentialStore(service: service)
            for provider in ProviderID.allCases {
                do {
                    try await store.deleteAPIKey(for: provider)
                    guard try await store.apiKey(for: provider) == nil else {
                        throw SpeakerDataErasureReason.verificationMismatch
                    }
                } catch let reason as SpeakerDataErasureReason {
                    throw reason
                } catch let error as ProviderCredentialStoreError {
                    throw Self.reason(for: error)
                } catch {
                    throw SpeakerDataErasureReason.io
                }
            }
        }
    }

    func verify() async throws {
        do {
            guard try !OwnerOnlyFilePersistence.regularFileExists(
                at: localFileURL
            ) else {
                throw SpeakerDataErasureReason.verificationMismatch
            }
        } catch let reason as SpeakerDataErasureReason {
            throw reason
        } catch {
            throw SpeakerDataErasureReason.unsafePath
        }
        for service in keychainServices {
            let store = KeychainProviderCredentialStore(service: service)
            for provider in ProviderID.allCases {
                do {
                    guard try await store.apiKey(for: provider) == nil else {
                        throw SpeakerDataErasureReason.verificationMismatch
                    }
                } catch let reason as SpeakerDataErasureReason {
                    throw reason
                } catch let error as ProviderCredentialStoreError {
                    throw Self.reason(for: error)
                } catch {
                    throw SpeakerDataErasureReason.io
                }
            }
        }
    }

    private func removeLocalCredentialFile() throws {
        do {
            _ = try OwnerOnlyFilePersistence.removeRegularFile(at: localFileURL)
        } catch let error as CocoaError
            where error.code == .fileWriteNoPermission
                || error.code == .fileReadNoPermission {
            throw SpeakerDataErasureReason.accessDenied
        } catch {
            throw SpeakerDataErasureReason.unsafePath
        }
    }

    private static func reason(
        for error: ProviderCredentialStoreError
    ) -> SpeakerDataErasureReason {
        switch error {
        case .accessDenied:
            .accessDenied
        case .interactionUnavailable:
            .interactionUnavailable
        case .emptyAPIKey, .apiKeyTooLarge, .malformedStoredValue, .conflictingStoredValues,
             .storageUnavailable:
            .io
        }
    }
}

@MainActor
enum SpeakerLoginItemEraser {
    static func erase() async throws {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try await service.unregister()
            } catch {
                throw SpeakerDataErasureReason.io
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            throw SpeakerDataErasureReason.verificationMismatch
        }
        try verify()
    }

    static func verify() throws {
        switch SMAppService.mainApp.status {
        case .notRegistered, .notFound:
            return
        case .enabled, .requiresApproval:
            throw SpeakerDataErasureReason.verificationMismatch
        @unknown default:
            throw SpeakerDataErasureReason.verificationMismatch
        }
    }
}
