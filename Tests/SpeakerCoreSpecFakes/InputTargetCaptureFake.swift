import Foundation
import SpeakerCore

/// An Input Target capture double that always answers with one injected result.
///
/// The injected result covers both shapes a case needs: a writable Input Target, and an
/// unavailable one that sends the session down the Pending Copy Result path.
public actor TargetCaptureFake: InputTargetCapturing, InputTargetDiscarding {
    public let result: InputTargetCaptureResult
    private let subsequentResult: InputTargetCaptureResult?
    private let delaysFirstCapture: Bool
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    public var hasPendingCapture: Bool { firstCaptureContinuation != nil }
    public private(set) var discardedCount = 0
    public private(set) var captureCount = 0
    public private(set) var captureHints: [InputTargetCaptureHint] = []

    public init(
        result: InputTargetCaptureResult, delaysFirstCapture: Bool = false,
        subsequentResult: InputTargetCaptureResult? = nil
    ) {
        self.result = result
        self.delaysFirstCapture = delaysFirstCapture
        self.subsequentResult = subsequentResult
    }

    public func capture() async -> InputTargetCaptureResult {
        captureCount += 1
        let result = captureCount == 1 ? self.result : subsequentResult ?? self.result
        if captureCount == 1, delaysFirstCapture {
            await withCheckedContinuation { firstCaptureContinuation = $0 }
        }
        return result
    }

    public func resumeFirstCapture() {
        firstCaptureContinuation?.resume()
        firstCaptureContinuation = nil
    }

    public func discard(_ target: InputTargetSnapshot) async {
        discardedCount += 1
    }

    public func capture(matching hint: InputTargetCaptureHint) async -> InputTargetCaptureResult {
        captureHints.append(hint)
        return await capture()
    }
}
