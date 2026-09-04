import SpeakerSpecSupport

/// One domain group of core specification cases.
///
/// Every domain runs its own cases through `run(failures:)`. That name hides the shared
/// harness function `run(_:failures:body:)` inside the domain's scope, so conformance
/// re-exposes it; `runAsync` needs no such forwarding.
protocol CoreSpecDomain {
    @MainActor
    static func run(failures: inout [String]) async
}

extension CoreSpecDomain {
    /// Runs one synchronous case through the shared harness.
    @MainActor
    static func run(
        _ name: String,
        failures: inout [String],
        body: () throws -> Void
    ) {
        SpeakerSpecSupport.run(name, failures: &failures, body: body)
    }
}
