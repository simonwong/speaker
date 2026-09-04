import Foundation
import SpeakerCore

/// An Input Target capture double that always answers with one injected result.
///
/// The injected result covers both shapes a case needs: a writable Input Target, and an
/// unavailable one that sends the session down the Pending Copy Result path.
public actor TargetCaptureFake: InputTargetCapturing {
    public let result: InputTargetCaptureResult
    public private(set) var captureCount = 0

    public init(result: InputTargetCaptureResult) {
        self.result = result
    }

    public func capture() async -> InputTargetCaptureResult {
        captureCount += 1
        return result
    }
}
