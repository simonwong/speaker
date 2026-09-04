import Darwin
import Foundation

/// A failed expectation inside one specification case.
public struct SpecFailure: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Fails the current case unless `condition` holds.
public func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expectation failed"
) throws {
    guard condition() else {
        throw SpecFailure(message: message)
    }
}

/// Fails the current case unless `operation` throws a `Failure`.
/// Any other error propagates unchanged so an unexpected failure is not mistaken for the expected one.
public func expectThrows<Failure: Error>(
    _ failureType: Failure.Type,
    _ message: String,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
    } catch is Failure {
        return
    }
    throw SpecFailure(message: message)
}

/// Which cases the current invocation runs.
///
/// Every specification executable accepts an optional name filter on its command line:
/// `swift run SpeakerCoreSpecs input target` runs only the cases whose name contains
/// "input target" (case-insensitive). Without arguments every case runs.
@MainActor
public enum SpecSelection {
    /// The case-insensitive substring a case name must contain to run, or `nil` for every case.
    public static var filter: String? = parse(CommandLine.arguments)

    /// Cases that ran in this process.
    public internal(set) static var executed = 0

    /// Cases skipped by the filter in this process.
    public internal(set) static var skipped = 0

    public static func matches(_ name: String) -> Bool {
        guard let filter else { return true }
        return name.localizedCaseInsensitiveContains(filter)
    }

    /// Whether each case name is written to stderr as it starts. Set
    /// `SPEAKER_SPEC_TRACE=1` to find the case a run hangs in.
    public static let traces =
        ProcessInfo.processInfo.environment["SPEAKER_SPEC_TRACE"] == "1"

    static func trace(_ name: String) {
        guard traces else { return }
        FileHandle.standardError.write(Data("▶ \(name)\n".utf8))
    }

    static func parse(_ arguments: [String]) -> String? {
        let words = arguments.dropFirst().filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}

/// Runs one synchronous case, recording a failure instead of aborting the executable.
@MainActor
public func run(
    _ name: String,
    failures: inout [String],
    body: () throws -> Void
) {
    guard SpecSelection.matches(name) else {
        SpecSelection.skipped += 1
        return
    }
    SpecSelection.executed += 1
    SpecSelection.trace(name)
    do {
        try body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

/// Runs one asynchronous case, recording a failure instead of aborting the executable.
@MainActor
public func runAsync(
    _ name: String,
    failures: inout [String],
    body: () async throws -> Void
) async {
    guard SpecSelection.matches(name) else {
        SpecSelection.skipped += 1
        return
    }
    SpecSelection.executed += 1
    SpecSelection.trace(name)
    do {
        try await body()
    } catch let failure as SpecFailure {
        failures.append("\(name): \(failure.message)")
    } catch {
        failures.append("\(name): \(error)")
    }
}

/// Polls `condition` until it holds or `timeout` elapses. Prefer this over sleeping before an assertion.
@MainActor
public func eventually(
    before timeout: Duration,
    pollEvery interval: Duration = .milliseconds(5),
    condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

/// End-of-run reporting shared by every specification executable.
@MainActor
public enum SpecSummary {
    /// Exit status when a name filter matched no case.
    public static let noMatchStatus: Int32 = 2

    /// Prints the outcome and exits non-zero on any failure or when a filter matched nothing.
    /// Returns normally only when every executed case passed, so callers keep their ordinary exit path.
    public static func finish(failures: [String], label: String) {
        if let filter = SpecSelection.filter, SpecSelection.executed == 0 {
            FileHandle.standardError.write(
                Data("FAIL: no \(label) matched \"\(filter)\" (\(SpecSelection.skipped) skipped)\n".utf8)
            )
            Darwin.exit(noMatchStatus)
        }
        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            FileHandle.standardError.write(
                Data("FAILED: \(failures.count) of \(SpecSelection.executed) \(label)\n".utf8)
            )
            Darwin.exit(1)
        }
        var line = "PASS: \(SpecSelection.executed) \(label)"
        if let filter = SpecSelection.filter {
            line += " matching \"\(filter)\" (\(SpecSelection.skipped) skipped)"
        }
        print(line)
    }
}
