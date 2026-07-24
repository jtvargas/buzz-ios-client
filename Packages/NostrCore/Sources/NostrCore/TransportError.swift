import Foundation

/// Why a ``RelayTransport`` operation could not complete.
///
/// The transport deals only in connection mechanics, so its failures form a
/// small closed set the consumer can switch on to drive reconnect and retry:
/// a connect that stalled versus one that was refused, a socket that is simply
/// gone, and the two directions of I/O. Protocol-level rejections (`OK(false)`,
/// `CLOSED`) are *not* here — those are a fully connected relay's verdict and
/// belong to ``OKReason``; this type is strictly about the pipe.
///
/// The failure detail on ``connectFailed(_:)`` / ``sendFailed(_:)`` /
/// ``receiveFailed(_:)`` is the underlying error rendered to a string rather
/// than the error itself, so the type stays `Equatable` and `Sendable` and can
/// cross actor boundaries and be asserted against directly in tests.
public enum TransportError: Error, Equatable, Sendable {
    /// The socket neither opened nor failed within the connect deadline — a
    /// black-holed TCP connect or a handshake that never completed. Distinct
    /// from ``connectFailed(_:)`` because a stall warrants a retry whereas an
    /// outright refusal may not.
    case connectTimeout
    /// The connect attempt failed outright (refused, unroutable, TLS failure).
    case connectFailed(String)
    /// An operation was issued against a socket that is not open — never
    /// connected, already closed, or dropped out from under the caller.
    case connectionClosed
    /// Writing a frame to the socket failed.
    case sendFailed(String)
    /// Reading the next frame from the socket failed.
    case receiveFailed(String)
    /// The peer delivered a frame in a form this transport does not model.
    case unsupportedFrame
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectTimeout:
            "The connection did not open within the timeout."
        case let .connectFailed(reason):
            "The connection failed: \(reason)"
        case .connectionClosed:
            "The connection is not open."
        case let .sendFailed(reason):
            "Sending a frame failed: \(reason)"
        case let .receiveFailed(reason):
            "Receiving a frame failed: \(reason)"
        case .unsupportedFrame:
            "The peer sent a frame of an unsupported kind."
        }
    }
}
