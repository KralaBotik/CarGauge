import Foundation

/// Finite outbound vocabulary. Raw responses never supply a command or an ECU address.
enum DiagnosticRequest: Equatable, Sendable {
    case protocolNumber, readiness, codes(DiagnosticCodeStatus), freezeCause
    case supported(base: UInt8, freeze: Bool)
    case sample(DiagnosticSensor, freeze: Bool)

    var wire: String {
        switch self {
        case .protocolNumber: "ATDPN"
        case .readiness: "0101"
        case .codes(let status): String(format: "%02X", status.service)
        case .freezeCause: "020200"
        case .supported(let base, let freeze): String(format: "%02X%02X", freeze ? 2 : 1, base) + (freeze ? "00" : "")
        case .sample(let sensor, let freeze): (freeze ? "02" : "01") + sensor.pid + (freeze ? "00" : "")
        }
    }

    static let pages: [UInt8] = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0]
    static let freezePages: [UInt8] = [0x00, 0x20, 0x40]
    // Profiles for extended modules remain metadata only until a documented
    // vehicle-specific addressing and read-command contract is implemented.
    static let allowed: Set<String> = {
        var requests: [Self] = [.protocolNumber, .readiness, .freezeCause]
        requests += DiagnosticCodeStatus.allCases.map { .codes($0) }
        requests += pages.map { .supported(base: $0, freeze: false) }
        requests += freezePages.map { .supported(base: $0, freeze: true) }
        for sensor in DiagnosticSensor.allCases {
            requests.append(.sample(sensor, freeze: false))
            requests.append(.sample(sensor, freeze: true))
        }
        return Set(requests.map(\.wire))
    }()
}

/// One manually started foreground survey. The caller schedules one request per
/// telemetry cycle; faults affecting the physical link are returned to its owner.
@MainActor public final class DiagnosticSurvey {
    public private(set) var report: DiagnosticReport
    public enum Scope: Equatable, Sendable { case full, codesOnly }
    private var remaining: [DiagnosticRequest]
    private let scope: Scope
    private var queuedAutomaticFreeze = false
    public private(set) var isExecuting = false

    public init(firstObservedCoolantAt: Date?, adapterName: String?, adapterIdentification: String? = nil,
                source: DataSource = .vehicle, stationaryConfirmedByUser: Bool = false,
                scope: Scope = .full, now: Date = .now) {
        self.scope = scope
        switch scope {
        case .full:
            remaining = [.protocolNumber, .supported(base: 0, freeze: false), .readiness,
                         .codes(.stored), .codes(.pending), .codes(.permanent), .freezeCause]
        case .codesOnly:
            remaining = [.protocolNumber, .codes(.stored), .codes(.pending), .codes(.permanent)]
        }
        report = DiagnosticReport(startedAt: now, firstObservedCoolantAt: firstObservedCoolantAt,
                                  adapterName: adapterName, adapterIdentification: adapterIdentification, source: source,
                                  stationaryConfirmedByUser: stationaryConfirmedByUser)
    }

    public func interrupt(_ reason: String, at now: Date = .now) {
        guard report.state == .running else { return }
        report.state = .interrupted
        report.finishedAt = now
        report.interruption = reason
        remaining.removeAll()
    }

    public func performNext(with client: ELM327Client) async throws {
        guard report.state == .running, !isExecuting else { return }
        // ISO 15031-5 only defines permanent DTC retrieval on ISO 15765-4.
        while case .codes(let status)? = remaining.first,
              report.transportProtocol == nil || (status == .permanent && report.transportProtocol?.usesCAN != true) {
            remaining.removeFirst()
        }
        guard !remaining.isEmpty else {
            complete()
            return
        }
        let request = remaining.removeFirst()
        isExecuting = true
        defer { isExecuting = false }
        let start = Date()
        let clock = ContinuousClock.now
        var raw: String?
        do {
            raw = try await client.exchangeDiagnostic(request)
            try Task.checkCancellation()
            if report.state == .running, let raw {
                try decode(request, raw: raw, at: .now)
                record(request, since: start, clock: clock, outcome: .received, raw: raw)
            } else {
                record(request, since: start, clock: clock, outcome: .cancelled, raw: raw)
            }
        } catch let error as OBDError where raw != nil && (error.isMissingSample || error == .unsupported) {
            let result: DiagnosticExchange.Outcome = switch error {
            case .noData: .noData
            case .unsupported: .unsupported
            default: .malformed
            }
            record(request, since: start, clock: clock, outcome: result, raw: raw, detail: error.errorDescription)
        } catch DiagnosticWireError.negative(let code) {
            record(request, since: start, clock: clock, outcome: .negative, raw: raw,
                   detail: String(format: "NRC %02X", code))
        } catch {
            let result: DiagnosticExchange.Outcome
            if error is CancellationError { result = .cancelled }
            else if error as? OBDError == .timeout { result = .timeout }
            else { result = .transportError }
            record(request, since: start, clock: clock, outcome: result, raw: raw, detail: error.localizedDescription)
            interrupt(error.localizedDescription)
            throw error
        }
        if remaining.isEmpty { complete() }
    }

    private func record(_ request: DiagnosticRequest, since start: Date, clock: ContinuousClock.Instant,
                        outcome: DiagnosticExchange.Outcome, raw: String?, detail: String? = nil) {
        let duration = clock.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        report.exchanges.append(DiagnosticExchange(command: request.wire, startedAt: start, finishedAt: .now,
                                                   elapsedMilliseconds: Int(milliseconds), outcome: outcome,
                                                   detail: detail, rawResponse: raw))
    }

    private func complete() {
        guard report.state == .running else { return }
        report.state = .completed
        report.finishedAt = .now
    }

    private func decode(_ request: DiagnosticRequest, raw: String, at now: Date) throws {
        switch request {
        case .protocolNumber:
            report.transportProtocol = try DiagnosticProtocol.identify(raw)
        case .readiness:
            let replies = try DiagnosticDecoder.modePID(mode: 1, pid: 1, bytes: 4, response: raw)
            report.readiness = replies.map(DiagnosticReadiness.init(bytes:))
        case .codes(let status):
            guard let framing = report.transportProtocol else { throw OBDError.unsupported }
            let values = try DiagnosticDecoder.troubleCodes(service: status.service, response: raw, framing: framing)
            report.codes.append(.init(status: status, replyGroups: values))
            if scope == .codesOnly, !queuedAutomaticFreeze, values.contains(where: { !$0.isEmpty }) {
                queuedAutomaticFreeze = true
                remaining.append(.freezeCause)
            }
        case .freezeCause:
            let replies = try DiagnosticDecoder.modePID(mode: 2, pid: 2, frame: 0, bytes: 2, response: raw)
            report.freezeCauses = replies.map {
                ($0[0] | $0[1]) == 0 ? "0000" : Self.code($0[0], $0[1])
            }
            if report.freezeCauses.contains(where: { $0 != "0000" }) {
                remaining.insert(.supported(base: 0, freeze: true), at: 0)
            }
        case .supported(let base, let freeze):
            try discover(base: base, freeze: freeze, raw: raw)
        case .sample(let sensor, let freeze):
            let replies = try DiagnosticDecoder.modePID(mode: freeze ? 2 : 1, pid: sensor.rawValue,
                                                       frame: freeze ? 0 : nil, bytes: sensor.byteCount, response: raw)
            report.measurements += replies.enumerated().map {
                DiagnosticMeasurement(sensor: sensor, value: sensor.value($0.element), rawBytes: $0.element, collectedAt: now,
                                      freezeFrame: freeze ? 0 : nil, responseIndex: $0.offset + 1)
            }
        }
    }

    private func discover(base: UInt8, freeze: Bool, raw: String) throws {
        let mode: UInt8 = freeze ? 2 : 1
        let replies = try DiagnosticDecoder.modePID(mode: mode, pid: base, frame: freeze ? 0 : nil,
                                                   bytes: 4, response: raw)
        let page = DiagnosticPage(mode: mode, basePID: base,
                                  masks: replies.map { $0.reduce(0) { ($0 << 8) | UInt32($1) } })
        report.pages.append(page)
        let pages = freeze ? DiagnosticRequest.freezePages : DiagnosticRequest.pages
        if base < 0xE0, pages.contains(base + 0x20), page.masks.contains(where: { $0 & 1 != 0 }) {
            remaining.insert(.supported(base: base + 0x20, freeze: freeze), at: 0)
        }
        remaining += DiagnosticSensor.allCases.filter(page.advertises).map { .sample($0, freeze: freeze) }
    }

    private static func code(_ first: UInt8, _ second: UInt8) -> String {
        let system = ["P", "C", "B", "U"][Int(first >> 6)]
        return system + String(format: "%01X%01X%02X", (first >> 4) & 3, first & 15, second)
    }
}
