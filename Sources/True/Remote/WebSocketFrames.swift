import Foundation
import CryptoKit

/// RFC 6455 pieces, pure so they are unit-tested without a socket.
enum WebSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client key (RFC 6455 §1.3).
    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    enum Opcode: UInt8 { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

    /// One server→client frame (never masked). FIN set, no fragmentation on send.
    static func encode(_ op: Opcode, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | op.rawValue]
        let n = payload.count
        if n < 126 { out.append(UInt8(n)) }
        else if n <= 0xFFFF { out.append(126); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF)) }
        else { out.append(127); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(s)) & 0xFF)) } }
        return out + payload
    }

    struct Message: Equatable { var op: Opcode; var payload: [UInt8] }

    /// Incremental client→server decoder: feed bytes as they arrive, get whole messages out.
    /// Reassembles fragmented data messages; control frames (≤125, never fragmented) pass through
    /// immediately. Clients MUST mask — an unmasked frame is a protocol error.
    struct Decoder {
        enum Failure: Error, Equatable { case unmasked, badOpcode, controlTooLong, tooLarge, badFragment }
        private var buf: [UInt8] = []
        private var partialOp: Opcode?
        private var partial: [UInt8] = []
        let maxMessage: Int
        init(maxMessage: Int = 1 << 20) { self.maxMessage = maxMessage }

        mutating func feed(_ bytes: [UInt8]) throws -> [Message] {
            buf += bytes
            var out: [Message] = []
            while let (fin, op, payload, used) = try parseOne() {
                buf.removeFirst(used)
                switch op {
                case .close, .ping, .pong:
                    out.append(Message(op: op, payload: payload))
                case .continuation:
                    guard let first = partialOp else { throw Failure.badFragment }
                    partial += payload
                    if partial.count > maxMessage { throw Failure.tooLarge }
                    if fin { out.append(Message(op: first, payload: partial)); partialOp = nil; partial = [] }
                case .text, .binary:
                    guard partialOp == nil else { throw Failure.badFragment }
                    if fin { out.append(Message(op: op, payload: payload)) }
                    else { partialOp = op; partial = payload }
                }
            }
            return out
        }

        private func parseOne() throws -> (Bool, Opcode, [UInt8], Int)? {
            guard buf.count >= 2 else { return nil }
            let b0 = buf[0], b1 = buf[1]
            let fin = b0 & 0x80 != 0
            guard let op = Opcode(rawValue: b0 & 0x0F) else { throw Failure.badOpcode }
            guard b1 & 0x80 != 0 else { throw Failure.unmasked }
            var len = Int(b1 & 0x7F)
            var idx = 2
            if len == 126 {
                guard buf.count >= 4 else { return nil }
                len = Int(buf[2]) << 8 | Int(buf[3]); idx = 4
            } else if len == 127 {
                guard buf.count >= 10 else { return nil }
                var v: UInt64 = 0
                for i in 2..<10 { v = v << 8 | UInt64(buf[i]) }
                guard v <= UInt64(maxMessage) else { throw Failure.tooLarge }
                len = Int(v); idx = 10
            }
            if op.rawValue >= 8 && (len > 125 || !fin) { throw Failure.controlTooLong }
            if len > maxMessage { throw Failure.tooLarge }
            guard buf.count >= idx + 4 + len else { return nil }
            let mask = Array(buf[idx..<idx + 4])
            idx += 4
            var payload = Array(buf[idx..<idx + len])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            return (fin, op, payload, idx + len)
        }
    }
}

/// Backpressure rule: a viewer more than 1 MB behind is not caught up by replaying the stream; it
/// gets a fresh screen snapshot and its queue is dropped.
enum RemoteBackpressure {
    static let limit = 1_048_576
    static func shouldSnapshot(pendingBytes: Int) -> Bool { pendingBytes > limit }
}
