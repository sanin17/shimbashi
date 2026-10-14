import Foundation

/// Abstraction over a WebSocket connection so `GeminiLiveConnection` can be
/// tested against a recorded/fake transcript instead of a live socket.
protocol WebSocketChannel: Sendable {
    func send(_ text: String) async throws
    /// Suspends until the next inbound message arrives, or throws when the
    /// connection ends. Must be called serially by a single reader.
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
    /// Best-effort explanation of why the connection ended, read after
    /// `receive()` throws. Defaults to empty for transports that can't say.
    var diagnostics: ChannelDiagnostics { get }
}

extension WebSocketChannel {
    var diagnostics: ChannelDiagnostics { ChannelDiagnostics() }
}

final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
        self.task = session.webSocketTask(with: request)
        // Default 1MB cap can truncate large model-audio messages.
        task.maximumMessageSize = 16 << 20
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    var diagnostics: ChannelDiagnostics {
        ChannelDiagnostics(
            httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
            closeCode: task.closeCode == .invalid ? nil : task.closeCode.rawValue,
            closeReason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        )
    }
}
