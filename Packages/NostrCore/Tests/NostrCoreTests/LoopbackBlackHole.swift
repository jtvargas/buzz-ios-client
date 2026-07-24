import Darwin
import Foundation

/// A loopback TCP socket that accepts connections at the kernel level but never
/// answers — a deterministic black hole for the open-timeout test.
///
/// It `bind`s and `listen`s on `127.0.0.1` but never `accept`s. The kernel
/// completes the TCP handshake for a listening socket up to its backlog, so a
/// `URLSessionWebSocketTask` connecting here reaches ESTABLISHED and sends its
/// HTTP upgrade request — which then sits unread forever. The upgrade never
/// completes, no pong ever returns, and the transport's own open timeout is the
/// only thing that resolves the connect. All on loopback: no external network,
/// no routing assumptions, no flakiness.
final class LoopbackBlackHole: @unchecked Sendable {
    /// The ephemeral port the socket is listening on.
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw Failure.socketCreation(errno)
        }

        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0 // let the kernel pick an ephemeral port

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fileDescriptor)
            throw Failure.bind(errno)
        }

        guard listen(fileDescriptor, 1) == 0 else {
            close(fileDescriptor)
            throw Failure.listen(errno)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(fileDescriptor)
            throw Failure.getsockname(errno)
        }

        descriptor = fileDescriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    func stop() {
        close(descriptor)
    }

    enum Failure: Error {
        case socketCreation(Int32)
        case bind(Int32)
        case listen(Int32)
        case getsockname(Int32)
    }
}
