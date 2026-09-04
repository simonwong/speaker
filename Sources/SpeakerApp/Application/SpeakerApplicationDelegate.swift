import AppKit

/// Hands the app's termination request to the runtime and replies to AppKit
/// only after the runtime has converged.
@MainActor
final class SpeakerTerminationCoordinator {
    var handler: (() async -> Void)?

    init() {}
}

final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    /// The one coordinator the runtime installs its shutdown handler on. The
    /// App passes it into the runtime's dependencies, so neither side reaches
    /// for a shared instance.
    @MainActor let terminationCoordinator = SpeakerTerminationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = terminationCoordinator.handler else {
            return .terminateNow
        }
        Task {
            await handler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
