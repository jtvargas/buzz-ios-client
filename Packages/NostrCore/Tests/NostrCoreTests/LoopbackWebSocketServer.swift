import CryptoKit
import Foundation

/// A one-connection websocket server on loopback, enough of RFC 6455 to answer a
/// `URLSessionWebSocketTask`: it completes the upgrade, answers pings, and sends
/// text frames on cue.
///
/// It exists because the transport's behaviour depends on *when the peer first
/// speaks*, which no in-process double can reproduce — the frame ordering under
/// test is `URLSession`'s own, inside the framework. A relay that greets on
/// connect and one that stays silent until spoken to are the two shapes the
/// client meets in the wild (a Buzz relay sends its NIP-42 challenge
/// immediately; `relay.damus.io` and `nos.lol` say nothing), and only a real
/// socket can put the transport in either.
final class LoopbackWebSocketServer: @unchecked Sendable {
    /// The ephemeral port the server is listening on.
    let port: UInt16

    /// What the server sends the moment the upgrade completes, before the client
    /// has said anything. Empty models a silent relay.
    private let greeting: String?
    /// What the server sends in reply to the client's first text frame.
    private let replies: [String]

    private let listener: Int32
    private let queue = DispatchQueue(label: "loopback.websocket.server")
    private var connection: Int32 = -1
    private var stopped = false

    init(greeting: String? = nil, replies: [String] = []) throws {
        self.greeting = greeting
        self.replies = replies

        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw Failure.socket(errno) }

        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fileDescriptor, 1) == 0 else {
            close(fileDescriptor)
            throw Failure.bind(errno)
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
            throw Failure.bind(errno)
        }

        listener = fileDescriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
        queue.async { [weak self] in self?.serve() }
    }

    var url: URL? { URL(string: "ws://127.0.0.1:\(port)") }

    func stop() {
        stopped = true
        if connection >= 0 { close(connection) }
        close(listener)
    }

    // MARK: - Serving

    private func serve() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        connection = client

        guard let key = readHandshakeKey(client) else { return }
        send(client, Data(upgradeResponse(acceptFor: key).utf8))

        if let greeting { send(client, textFrame(greeting)) }

        var repliesLeft = replies
        while !stopped {
            guard let frame = readFrame(client) else { return }
            switch frame.opcode {
            case 0x9: // ping — the transport's open probe depends on the pong
                send(client, controlFrame(opcode: 0xA, payload: frame.payload))
            case 0x1, 0x2: // the client spoke: answer, if there is an answer left
                guard !repliesLeft.isEmpty else { continue }
                for reply in repliesLeft { send(client, textFrame(reply)) }
                repliesLeft = []
            case 0x8: // close
                return
            default:
                continue
            }
        }
    }

    /// Reads the upgrade request and returns its `Sec-WebSocket-Key`.
    private func readHandshakeKey(_ client: Int32) -> String? {
        var request = Data()
        var byte: UInt8 = 0
        while request.count < 4096, !request.hasSuffix("\r\n\r\n") {
            guard read(client, &byte, 1) == 1 else { return nil }
            request.append(byte)
        }
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("sec-websocket-key:") {
            return line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func upgradeResponse(acceptFor key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(digest).base64EncodedString()
        return """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
    }

    // MARK: - Framing

    private struct Frame {
        let opcode: UInt8
        let payload: Data
    }

    /// Reads one client frame. Clients always mask, and no frame this test sends
    /// is long enough to need the 64-bit length form.
    private func readFrame(_ client: Int32) -> Frame? {
        var header = [UInt8](repeating: 0, count: 2)
        guard readFully(client, &header, 2) else { return nil }
        let opcode = header[0] & 0x0F
        let masked = header[1] & 0x80 != 0
        var length = Int(header[1] & 0x7F)

        if length == 126 {
            var extended = [UInt8](repeating: 0, count: 2)
            guard readFully(client, &extended, 2) else { return nil }
            length = Int(extended[0]) << 8 | Int(extended[1])
        }

        var mask = [UInt8](repeating: 0, count: 4)
        if masked, !readFully(client, &mask, 4) { return nil }

        var payload = [UInt8](repeating: 0, count: length)
        if length > 0, !readFully(client, &payload, length) { return nil }
        if masked {
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        return Frame(opcode: opcode, payload: Data(payload))
    }

    private func readFully(_ client: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ count: Int) -> Bool {
        var read = 0
        while read < count {
            let got = Darwin.read(client, buffer + read, count - read)
            guard got > 0 else { return false }
            read += got
        }
        return true
    }

    private func textFrame(_ text: String) -> Data {
        controlFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// A server frame: FIN set, never masked, short-or-16-bit length.
    private func controlFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        return frame
    }

    private func send(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let sent = Darwin.write(client, base + written, buffer.count - written)
                guard sent > 0 else { return }
                written += sent
            }
        }
    }

    enum Failure: Error {
        case socket(Int32)
        case bind(Int32)
    }
}

private extension Data {
    func hasSuffix(_ string: String) -> Bool {
        let needle = Data(string.utf8)
        guard count >= needle.count else { return false }
        return Data(dropFirst(count - needle.count)) == needle
    }
}
