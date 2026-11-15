import Foundation

/// A response's status, then its body line by line as it arrives: server-sent events, NDJSON.
public struct LineStream: Sendable {
    public typealias Lines = AsyncThrowingStream<String, any Error>

    public let response: HTTPURLResponse
    public let lines: Lines

    public init(response: HTTPURLResponse, lines: Lines) {
        self.response = response
        self.lines = lines
    }

    public var status: Int { response.statusCode }
}

/// Opens a long-lived response and hands over its lines. The streaming twin of `HTTPTransport`: kits take one from
/// their host, and only this package makes a `URLSession`. Cancelling the consumer of `lines` closes the connection.
public protocol StreamingTransport: Sendable {
    func open(_ request: URLRequest) async throws -> LineStream
}

/// `URLSession`'s bytes, split into lines. The policy's request timeout is the longest silence between bytes, so a
/// server's keep-alive must come more often than that; streams never wait for a network to appear, as a read would.
public struct URLSessionStreamingTransport: StreamingTransport {
    private let session: URLSession

    public init(quietLimit: TimeInterval) {
        session = SessionPolicy(requestTimeout: quietLimit, waitsForConnectivity: false).makeSession()
    }

    public func open(_ request: URLRequest) async throws -> LineStream {
        let (bytes, response) = try await session.bytes(for: URLSessionTransport.preferringHTTP3(request))
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw HTTPTransportError.notHTTP
        }
        let lines = LineStream.Lines { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return LineStream(response: http, lines: lines)
    }
}
