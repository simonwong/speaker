import Combine
import Foundation

public enum PermissionKind: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case microphone
}

public enum PermissionState: String, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var accessibility: PermissionState
    public var microphone: PermissionState

    public init(
        accessibility: PermissionState,
        microphone: PermissionState
    ) {
        self.accessibility = accessibility
        self.microphone = microphone
    }

    public var allGranted: Bool {
        accessibility == .granted && microphone == .granted
    }

    public subscript(permission: PermissionKind) -> PermissionState {
        switch permission {
        case .accessibility:
            accessibility
        case .microphone:
            microphone
        }
    }
}

@MainActor
public protocol PermissionAccess: AnyObject {
    func currentSnapshot() -> PermissionSnapshot
    func request(_ permission: PermissionKind) async -> PermissionSnapshot
}

@MainActor
public final class PermissionModel: ObservableObject {
    @Published public private(set) var snapshot: PermissionSnapshot

    private let access: any PermissionAccess

    public init(access: any PermissionAccess) {
        self.access = access
        snapshot = access.currentSnapshot()
    }

    public func refresh() {
        snapshot = access.currentSnapshot()
    }

    public func request(_ permission: PermissionKind) async {
        snapshot = await access.request(permission)
    }
}

