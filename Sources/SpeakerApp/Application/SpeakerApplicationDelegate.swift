import AppKit

final class SpeakerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = SpeakerTerminationCoordinator.shared.handler else {
            return .terminateNow
        }
        Task {
            await handler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class SpeakerTerminationCoordinator {
    static let shared = SpeakerTerminationCoordinator()
    var handler: (() async -> Void)?
}
