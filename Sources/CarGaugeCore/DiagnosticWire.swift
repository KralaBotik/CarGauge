import Foundation

/// The standard emissions transports that ELM327 reports through ATDPN.
public enum DiagnosticProtocol: String, Codable, Sendable {
    case saeJ1850PWM = "1"
    case saeJ1850VPW = "2"
    case iso9141 = "3"
    case iso14230Slow = "4"
    case iso14230Fast = "5"
    case can11Bit500 = "6"
    case can29Bit500 = "7"
    case can11Bit250 = "8"
    case can29Bit250 = "9"

    public var usesCAN: Bool {
        switch self {
        case .can11Bit500, .can29Bit500, .can11Bit250, .can29Bit250: true
        default: false
        }
    }

    public static func identify(_ response: String) throws -> Self {
        let lines = try DiagnosticDecoder.normalizedLines(response, echo: "ATDPN")
        guard lines.count == 1, let reported = lines.first else {
            throw OBDError.malformedResponse
        }
        // Automatic protocol selection adds an A prefix to the actual number.
        // A by itself is J1939, while 0 is an unresolved search.
        let code = reported.count == 2 && reported.hasPrefix("A") ? String(reported.dropFirst()) : reported
        guard code.count == 1, let digit = code.first, digit.isASCII && digit.isHexDigit else {
            throw OBDError.malformedResponse
        }
        guard let result = Self(rawValue: code) else { throw OBDError.unsupported }
        return result
    }
}

public enum DiagnosticWireError: Error, Equatable, Sendable, LocalizedError {
    case negative(UInt8)

    public var errorDescription: String? {
        switch self {
        case .negative(let code): "Отрицательный ответ ЭБУ (\(String(format: "%02X", code)))"
        }
    }
}

public enum DiagnosticDecoder {
    public static func troubleCodes(service: UInt8, response: String,
                                   framing: DiagnosticProtocol) throws -> [[String]] {
        guard [0x03, 0x07, 0x0A].contains(service), service != 0x0A || framing.usesCAN else {
            throw OBDError.unsupported
        }
        let command = String(format: "%02X", service)
        return try messages(response, echo: command, allowMultiframe: framing.usesCAN).map { frame in
            try checkNegative(frame, service: service)
            guard frame.first == service + 0x40 else { throw OBDError.malformedResponse }
            if framing.usesCAN {
                guard frame.count >= 2, frame.count == 2 + 2 * Int(frame[1]) else {
                    throw OBDError.malformedResponse
                }
                return try codes(frame.dropFirst(2), padded: false)
            }
            // Legacy services 03 and 07 supply three slots per response. A slot
            // of 00 00 indicates unused trailing space, not an actual DTC.
            guard frame.count == 7 else { throw OBDError.malformedResponse }
            return try codes(frame.dropFirst(), padded: true)
        }
    }

    public static func modePID(mode: UInt8, pid: UInt8, frame: UInt8? = nil,
                               bytes: Int, response: String) throws -> [[UInt8]] {
        guard mode == 0x01 || mode == 0x02 else { throw OBDError.unsupported }
        guard (mode == 0x02) == (frame != nil), (1...(frame == nil ? 5 : 4)).contains(bytes) else {
            throw OBDError.malformedResponse
        }
        let frameByte = frame.map { [$0] } ?? []
        let request = [mode, pid] + frameByte
        let prefix = [mode + 0x40, pid] + frameByte
        let command = request.map { String(format: "%02X", $0) }.joined()
        return try messages(response, echo: command, allowMultiframe: false).map { message in
            try checkNegative(message, service: mode)
            guard message.count == prefix.count + bytes, message.starts(with: prefix) else {
                throw OBDError.malformedResponse
            }
            return Array(message.dropFirst(prefix.count))
        }
    }

    private static func checkNegative(_ payload: [UInt8], service: UInt8) throws {
        guard payload.first == 0x7F else { return }
        guard payload.count == 3, payload[1] == service else { throw OBDError.malformedResponse }
        throw DiagnosticWireError.negative(payload[2])
    }

    private static func codes(_ data: ArraySlice<UInt8>, padded: Bool) throws -> [String] {
        var result: [String] = []
        var reachedPadding = false
        for byteIndex in stride(from: data.startIndex, to: data.endIndex, by: 2) {
            let first = data[byteIndex]
            let second = data[byteIndex + 1]
            if first == 0 && second == 0 {
                guard padded else { throw OBDError.malformedResponse }
                reachedPadding = true
                continue
            }
            guard !reachedPadding else { throw OBDError.malformedResponse }
            let system = ["P", "C", "B", "U"][Int(first >> 6)]
            result.append(system + String(format: "%1X%1X%02X", (first >> 4) & 3, first & 15, second))
        }
        return result
    }

    /// ATH0, ATS0 and default CAF1. Each complete message is kept separate.
    /// With headers disabled there is no ECU identity to recover across replies.
    private static func messages(_ response: String, echo: String,
                                 allowMultiframe: Bool) throws -> [[UInt8]] {
        let lines = try normalizedLines(response, echo: echo)
        guard !lines.isEmpty else { throw OBDError.malformedResponse }
        var result: [[UInt8]] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1
            if allowMultiframe, line.count == 3, line.allSatisfy(\.isHexDigit),
               let length = Int(line, radix: 16), (8...0xFFF).contains(length) {
                result.append(try readMultiframe(lines, index: &index, length: length))
            } else {
                let bytes = try hexBytes(line[...])
                guard bytes.count <= 7 else { throw OBDError.malformedResponse }
                result.append(bytes)
            }
        }
        return result
    }

    /// CAF1 emits a three-digit hex length, then a six-byte first frame and
    /// seven-byte consecutive frames. The last can include zero filler. ELM can interleave
    /// replies from several ECUs. Reject overlaps instead of splicing them.
    private static func readMultiframe(_ lines: [String], index: inout Int, length: Int) throws -> [UInt8] {
        var message: [UInt8] = []
        var sequence = 0
        while message.count < length {
            guard index < lines.count else { throw OBDError.malformedResponse }
            let line = lines[index]
            let prefix = String(format: "%X:", sequence & 0x0F)
            guard line.hasPrefix(prefix) else { throw OBDError.malformedResponse }
            let payload = try hexBytes(line.dropFirst(prefix.count))
            let expectedSize = min(sequence == 0 ? 6 : 7, length - message.count)
            let paddedLast = sequence > 0 && expectedSize < 7 && payload.count == 7
                && payload.dropFirst(expectedSize).allSatisfy { $0 == 0 }
            guard payload.count == expectedSize || paddedLast else { throw OBDError.malformedResponse }
            message.append(contentsOf: payload.prefix(expectedSize))
            index += 1
            sequence += 1
        }
        return message
    }

    fileprivate static func normalizedLines(_ response: String, echo: String) throws -> [String] {
        let serial = response.utf8
        guard serial.count <= ELMPromptBuffer().limit else { throw OBDError.bufferOverflow }
        guard serial.allSatisfy({ $0 < 0x80 }) else { throw OBDError.malformedResponse }
        if let prompt = serial.firstIndex(of: 0x3E) {
            // Transport normally strips the prompt. A saved complete transcript
            // can include it, but must never contain another command response.
            guard ELMPromptBuffer.isPadding(serial[serial.index(after: prompt)...]) else {
                throw OBDError.malformedResponse
            }
        }
        let cleaned = try response.uppercased().components(separatedBy: .newlines).map { line in
            let compact = line.filter { !$0.isWhitespace }
            let payload = compact.hasPrefix("SEARCHING...") ? String(compact.dropFirst(12)) : compact
            guard !payload.contains("SEARCHING...") else { throw OBDError.malformedResponse }
            return payload
        }
        return try OBDDecoder.lines(cleaned.joined(separator: "\r"), echo: echo)
    }

    private static func hexBytes(_ line: Substring) throws -> [UInt8] {
        guard !line.isEmpty, line.utf8.count.isMultiple(of: 2),
              line.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw OBDError.malformedResponse }
        var result: [UInt8] = []
        var index = line.startIndex
        while index < line.endIndex {
            let end = line.index(index, offsetBy: 2)
            guard let byte = UInt8(line[index..<end], radix: 16) else { throw OBDError.malformedResponse }
            result.append(byte)
            index = end
        }
        return result
    }
}
