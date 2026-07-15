import Combine
import Foundation

@MainActor
public final class VoiceInputSessionModel: ObservableObject {
    @Published public private(set) var presentation = VoiceInputPresentation(
        revision: 0,
        activity: .idle
    )

    public let sessions: VoiceInputSessions
    private var observationTask: Task<Void, Never>?

    public init(sessions: VoiceInputSessions) {
        self.sessions = sessions
    }

    public func startObserving() {
        guard observationTask == nil else { return }
        let sessions = sessions
        observationTask = Task { [weak self] in
            let stream = await sessions.observe()
            for await presentation in stream {
                guard !Task.isCancelled else { return }
                self?.presentation = presentation
            }
        }
    }

    public func send(_ command: VoiceInputCommand) {
        let sessions = sessions
        Task {
            await sessions.send(command)
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
