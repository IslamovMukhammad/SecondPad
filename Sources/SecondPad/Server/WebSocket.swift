import CryptoKit
import Foundation

/// RFC 6455, only what a dashboard needs: text frames, ping/pong, close. Pure, unit-tested.
nonisolated enum WebSocket {

    /// The largest frame the tablet may send. Its commands are a few hundred bytes.
    static let maxPayload = 64 * 1024

    static func acceptKey(for key: String) -> String {
        let magic = key.trimmingCharacters(in: .whitespaces) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        return Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
    }

    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    struct Frame: Equatable {
        let fin: Bool
        let opcode: Opcode
        let payload: Data
    }

    enum Decode: Equatable {
        case frame(Frame, consumed: Int)
        case incomplete
        /// Unmasked client frame, unknown opcode, or too large: close the connection.
        case invalid
    }

    /// Client frames must be masked.
    static func decode(_ data: Data, requireMask: Bool = true) -> Decode {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return .incomplete }
        let fin = bytes[0] & 0x80 != 0
        guard bytes[0] & 0x70 == 0, let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { return .invalid }
        let masked = bytes[1] & 0x80 != 0
        if requireMask && !masked { return .invalid }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return .incomplete }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .incomplete }
            var value: UInt64 = 0
            for i in 2..<10 { value = value << 8 | UInt64(bytes[i]) }
            guard value <= UInt64(maxPayload) else { return .invalid }
            length = Int(value)
            offset = 10
        }
        guard length <= maxPayload else { return .invalid }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return .incomplete }
            mask = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard data.count >= offset + length else { return .incomplete }
        let start = data.startIndex + offset
        var payload = [UInt8](data[start..<start + length])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        return .frame(Frame(fin: fin, opcode: opcode, payload: Data(payload)), consumed: offset + length)
    }

    /// Server frames are never masked.
    static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(count >> 8)); out.append(UInt8(count & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    static func text(_ string: String) -> Data { encode(.text, Data(string.utf8)) }
}
