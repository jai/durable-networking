import Foundation

/// Why a read brought nothing new.
public enum ReadFailure: Error, Equatable, Sendable {
    /// No network, or it dropped the request.
    case offline
    /// A 2xx the app can't read: a captive portal answers 200 with its own page.
    case unreadable
    /// The server answered, and not with the data.
    case refused(status: Int, reason: String)
    case failed(reason: String)

    /// A `ReadFailure` as it is; a dropped connection is `offline`; a body that doesn't decode is `unreadable`.
    public static func of(_ error: any Error) -> ReadFailure {
        if let failure = error as? ReadFailure {
            return failure
        }
        if RetryingTransport.isDroppedByNetwork(error) {
            return .offline
        }
        if error is DecodingError {
            return .unreadable
        }
        return .failed(reason: error.localizedDescription)
    }
}

/// What a screen holds of one read. One case each, so a view can't show a spinner over data it has or call kept data
/// current.
public enum ReadState<Value: Sendable>: Sendable {
    /// Nothing yet, and no read has failed.
    case empty
    /// Nothing, and the read failed.
    case unreachable(ReadFailure)
    /// Kept from an earlier launch; this launch's read hasn't answered.
    case cached(Value, savedAt: Date)
    /// Read since launch.
    case fresh(Value, readAt: Date)
    /// Held, and the last refresh failed.
    case stale(Value, savedAt: Date, failure: ReadFailure)

    public var value: Value? {
        switch self {
        case .empty, .unreachable: nil
        case .cached(let value, _), .fresh(let value, _), .stale(let value, _, _): value
        }
    }

    /// When the value on screen was read from the server.
    public var savedAt: Date? {
        switch self {
        case .empty, .unreachable: nil
        case .cached(_, let readAt), .fresh(_, let readAt), .stale(_, let readAt, _): readAt
        }
    }

    /// Why the last read failed, while nothing has answered since.
    public var failure: ReadFailure? {
        switch self {
        case .unreachable(let failure), .stale(_, _, let failure): failure
        case .empty, .cached, .fresh: nil
        }
    }

    /// The one transition function. Kept data arrives only before any value: a later one would be older than what is
    /// on screen, so it is refused here.
    public func after(_ event: ReadEvent<Value>) -> ReadState {
        switch (self, event) {
        case (_, .answered(let value, let readAt)):
            .fresh(value, readAt: readAt)
        case (_, .forgotten):
            .empty
        case (.empty, .kept(let value, let savedAt)):
            .cached(value, savedAt: savedAt)
        case (.unreachable(let failure), .kept(let value, let savedAt)):
            .stale(value, savedAt: savedAt, failure: failure)
        case (.cached, .kept), (.fresh, .kept), (.stale, .kept):
            self
        case (.empty, .failed(let failure)), (.unreachable, .failed(let failure)):
            .unreachable(failure)
        case (.cached(let value, let readAt), .failed(let failure)),
             (.fresh(let value, let readAt), .failed(let failure)),
             (.stale(let value, let readAt, _), .failed(let failure)):
            .stale(value, savedAt: readAt, failure: failure)
        }
    }
}

extension ReadState: Equatable where Value: Equatable {}

/// What happened to a read.
public enum ReadEvent<Value: Sendable>: Sendable {
    /// The device's copy, from an earlier launch.
    case kept(Value, savedAt: Date)
    /// The server's answer.
    case answered(Value, readAt: Date)
    case failed(ReadFailure)
    /// The server no longer has it.
    case forgotten
}
