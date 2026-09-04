package enum DataErasureWorkspaceRoute: Equatable, Sendable {
    case normal
    case erasing
    case aboutRecovery
}

extension SpeakerDataErasureState {
    package var workspaceRoute: DataErasureWorkspaceRoute {
        switch self {
        case .idle: .normal
        case .erasing: .erasing
        case .failed: .aboutRecovery
        }
    }
}
