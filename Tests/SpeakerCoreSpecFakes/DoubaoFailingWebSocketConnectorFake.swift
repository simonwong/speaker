import Foundation
import SpeakerCore

package struct DoubaoFailingWebSocketConnectorFake: DoubaoWebSocketConnecting {
    private let error: URLError

    package init(error: URLError) {
        self.error = error
    }

    package func connect(
        _ request: URLRequest
    ) async throws -> any DoubaoWebSocketConnection {
        throw error
    }
}
