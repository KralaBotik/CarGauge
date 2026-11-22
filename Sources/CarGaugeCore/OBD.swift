import Foundation

public enum OBDPID: String, CaseIterable, Sendable {
    case coolant = "0105"
    case rpm = "010C"
    case moduleVoltage = "0142"

    var responsePrefix: String { "41" + rawValue.suffix(2) }
    var payloadBytes: Int { self == .coolant ? 1 : 2 }
}

public enum OBDSupportPage: String, CaseIterable, Sendable {
    case pids01To20 = "0100"
    case pids41To60 = "0140"

    var responsePrefix: String { "41" + rawValue.suffix(2) }
    var firstPID: Int { self == .pids01To20 ? 0x01 : 0x41 }
}

public struct OBDSupportMask: Equatable, Sendable {
    public let page: OBDSupportPage
    public let bits: UInt32

    /// A negative mask is informational; an ECU that responds to a direct query wins.
    public func reportsSupport(for pid: OBDPID) -> Bool? {
        guard let code = Int(pid.rawValue.suffix(2), radix: 16) else { return nil }
        let index = code - page.firstPID
        guard (0..<32).contains(index) else { return nil }
        return (bits & (0x8000_0000 >> index)) != 0
    }
}

public enum OBDError: Error, Equatable, Sendable, LocalizedError {
    case disconnected, timeout, busy, noData, unsupported, malformedResponse, ambiguousResponse, bufferOverflow
    case adapter(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "Соединение потеряно"
        case .timeout: "Адаптер не ответил вовремя"
        case .busy: "Предыдущая команда ещё выполняется"
        case .noData: "ECU не предоставил данные"
        case .unsupported: "Команда не поддерживается"
        case .malformedResponse: "Некорректный ответ адаптера"
        case .ambiguousResponse: "Разные ответы от нескольких ECU"
        case .bufferOverflow: "Ответ адаптера слишком длинный"
        case .adapter(let message): "Адаптер: \(message)"
        }
    }

    var isMissingSample: Bool { self == .noData || self == .malformedResponse || self == .ambiguousResponse }
}

/// One command at a time, including its terminating ELM prompt.
@MainActor public protocol OBDTransport: AnyObject {
    func connect() async throws
    func disconnect()
    func exchange(_ command: String, timeout: TimeInterval) async throws -> String
}

/// BLE notifications may split a response anywhere, including before the prompt.
public struct ELMPromptBuffer: Sendable {
    private var bytes: [UInt8] = []
    public let limit: Int

    public init(limit: Int = 4096) { self.limit = limit }

    public mutating func append(_ data: Data) throws -> [String] {
        var frames: [String] = []
        for byte in data {
            if byte == 0x3E {
                guard let text = String(bytes: bytes, encoding: .ascii) else {
                    reset()
                    throw OBDError.malformedResponse
                }
                frames.append(text)
                bytes.removeAll(keepingCapacity: true)
            } else {
                guard bytes.count < limit else {
                    reset()
                    throw OBDError.bufferOverflow
                }
                bytes.append(byte)
            }
        }
        return frames
    }

    public mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    public var hasPartialPayload: Bool { !Self.isPadding(bytes) }

    public static func isPadding(_ bytes: some Sequence<UInt8>) -> Bool {
        bytes.allSatisfy { [0x09, 0x0A, 0x0D, 0x20].contains($0) }
    }
}

/// Collects one response for one command, including any tail received before the next write.
public struct ELMCommandFrame: Sendable {
    private var buffer = ELMPromptBuffer()
    public private(set) var response: String?

    public init() {}

    public mutating func append(_ data: Data) throws -> Bool {
        if response != nil {
            guard ELMPromptBuffer.isPadding(data) else { throw OBDError.malformedResponse }
            return false
        }
        let frames = try buffer.append(data)
        guard let first = frames.first else { return false }
        guard frames.count == 1, !buffer.hasPartialPayload else { throw OBDError.malformedResponse }
        response = first
        return true
    }
}

public enum OBDDecoder {
    public static func lines(_ response: String, echo: String) throws -> [String] {
        let lines = response.uppercased()
            .replacingOccurrences(of: "SEARCHING...", with: "")
            .replacingOccurrences(of: ">", with: "\r")
            .components(separatedBy: .newlines)
            .map { $0.filter { !$0.isWhitespace } }
            .filter { !$0.isEmpty && $0 != echo.uppercased().filter { !$0.isWhitespace } }
        for line in lines {
            if line == "NODATA" { throw OBDError.noData }
            if line == "?" { throw OBDError.unsupported }
            if ["STOPPED", "UNABLETOCONNECT", "CANERROR", "BUSERROR", "BUSINIT:ERROR",
                "BUFFERFULL", "LVRESET", "FBERROR", "DATAERROR", "<DATAERROR"].contains(line) {
                throw OBDError.adapter(line)
            }
        }
        return lines
    }

    /// ATH0 / ATS0 responses only. Unknown headers and truncated payloads are rejected.
    public static func decode(_ pid: OBDPID, response: String) throws -> Double {
        let lines = try lines(response, echo: pid.rawValue)
        var values: [Double] = []
        for line in lines {
            guard line.hasPrefix(pid.responsePrefix),
                  line.count == 4 + pid.payloadBytes * 2 else { throw OBDError.malformedResponse }
            let payload = String(line.dropFirst(4))
            guard payload.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                  let value = UInt16(payload, radix: 16) else { throw OBDError.malformedResponse }
            switch pid {
            case .coolant: values.append(Double(value) - 40)
            case .rpm: values.append(Double(value) / 4)
            case .moduleVoltage: values.append(Double(value) / 1000)
            }
        }
        guard let first = values.first else { throw OBDError.malformedResponse }
        guard values.allSatisfy({ $0 == first }) else { throw OBDError.ambiguousResponse }
        return first
    }

    public static func supportMask(_ page: OBDSupportPage, response: String) throws -> OBDSupportMask {
        let lines = try lines(response, echo: page.rawValue)
        var reported: UInt32?
        for line in lines {
            let payload = line.dropFirst(4)
            guard line.hasPrefix(page.responsePrefix), payload.count == 8,
                  payload.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let mask = UInt32(payload, radix: 16) else { throw OBDError.malformedResponse }
            guard reported == nil || reported == mask else { throw OBDError.ambiguousResponse }
            reported = mask
        }
        guard let reported else { throw OBDError.malformedResponse }
        return OBDSupportMask(page: page, bits: reported)
    }

    public static func adapterVoltage(_ response: String) throws -> Double {
        let lines = try lines(response, echo: "ATRV")
        guard lines.count == 1, let line = lines.first, line.hasSuffix("V"),
              let value = Double(line.dropLast()), value.isFinite, (0...30).contains(value) else {
            throw OBDError.malformedResponse
        }
        return value
    }
}
