/// Product policy for exposing Speaker in the Dock and Command-Tab while its
/// main window is open. Platform code translates the semantic policy into an
/// AppKit activation policy.
package enum MainWindowActivationPolicy: Equatable, Sendable {
    case accessory
    case regular
}

@MainActor
package final class MainWindowVisibilityFeature {
    private let applyActivationPolicy: (MainWindowActivationPolicy) -> Void
    private var activationPolicy: MainWindowActivationPolicy = .accessory

    package init(
        applyActivationPolicy: @escaping (MainWindowActivationPolicy) -> Void
    ) {
        self.applyActivationPolicy = applyActivationPolicy
    }

    package func mainWindowDidOpen() {
        transition(to: .regular)
    }

    package func mainWindowWillClose() {
        transition(to: .accessory)
    }

    private func transition(to policy: MainWindowActivationPolicy) {
        guard policy != activationPolicy else { return }
        activationPolicy = policy
        applyActivationPolicy(policy)
    }
}
