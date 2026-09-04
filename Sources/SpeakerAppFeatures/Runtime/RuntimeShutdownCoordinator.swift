import Foundation

/// The steps every shutdown path runs, in the order `RuntimeShutdownCoordinator`
/// calls them. App termination and the quiesce before local-data erasure both
/// converge through the same sequence.
@MainActor
package protocol RuntimeShutdownStages: AnyObject {
    /// Stop the global trigger so no new session can start.
    func stopTrigger()
    /// Stop reacting to permission changes.
    func stopPermissionRefresh()
    /// Ask the startup sequence to stop at its next checkpoint.
    func cancelStartup()
    /// Close the onboarding window if it is open.
    func closeOnboarding()
    /// Hide the Voice Input panel.
    func closePanel()
    /// Let the refinement settings finish their in-flight work.
    func shutdownRefinement() async
    /// Let the Doubao settings finish their in-flight work.
    func shutdownDoubao() async
    /// Finish or cancel the current Voice Input Session and flush history.
    func shutdownVoiceInput() async
    /// Wait for the cancelled startup sequence to leave its current stage.
    func awaitStartup() async
    /// Wait for the last persisted preference write.
    func flushPersistence() async
}

/// Runs the shutdown stages exactly once per process.
///
/// Termination and erasure can both ask for convergence; whichever arrives
/// second waits for the run already in flight instead of starting another, so
/// every stage observes the same ordering and no module is shut down twice.
@MainActor
package final class RuntimeShutdownCoordinator {
    private let stages: any RuntimeShutdownStages
    private var convergence: Task<Void, Never>?

    package init(stages: any RuntimeShutdownStages) {
        self.stages = stages
    }

    /// Whether convergence has started. It never resets.
    package var hasStarted: Bool { convergence != nil }

    /// Runs the stages in order, or waits for the run already in progress.
    package func converge() async {
        if let convergence {
            await convergence.value
            return
        }
        let stages = self.stages
        let task = Task { @MainActor in
            await Self.run(stages)
        }
        convergence = task
        await task.value
    }

    private static func run(_ stages: any RuntimeShutdownStages) async {
        stages.stopTrigger()
        stages.stopPermissionRefresh()
        stages.cancelStartup()
        stages.closeOnboarding()
        stages.closePanel()
        await stages.shutdownRefinement()
        await stages.shutdownDoubao()
        await stages.shutdownVoiceInput()
        await stages.awaitStartup()
        await stages.flushPersistence()
    }
}
