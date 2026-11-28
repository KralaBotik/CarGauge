import CSQLite
import Foundation

public enum VehicleReportScope: Hashable, Sendable {
    case trip(Int64?), problem(UUID), survey, diagnostics, servicing
}

public enum VehicleReportFormat: String, CaseIterable, Sendable {
    case json, csv, txt

    public var title: String {
        switch self {
        case .json: "Отчёт JSON"
        case .csv: "Телеметрия CSV"
        case .txt: "Сводка TXT"
        }
    }
}

public struct ArchivedReading: Codable, Sendable {
    public let trip: Int64
    public let time: Date
    public let elapsedSeconds: Double
    public let parameter: String
    public let unit: String
    public let value: Double?
    public let quality: String
    public let source: String
    public let dataHex: String?
}

public struct ArchivedGap: Codable, Sendable {
    public let trip: Int64
    public let start: Date
    public let resume: Date?
    public let reason: String
}

struct ReportSurvey: Encodable {
    struct Exchange: Encodable {
        let command: String
        let start: Date
        let finish: Date
        let durationMilliseconds: Int
        let outcome: DiagnosticExchange.Outcome
        let rawResponse: String?
        let detail: String?
    }

    let id: UUID
    let started: Date
    let finished: Date?
    let state: DiagnosticReport.State
    let adapter: String?
    let protocolName: String?
    let source: String
    let firstObservedCoolantAt: Date?
    let stationaryConfirmed: Bool
    let modules: [DiagnosticReport.Module]
    let codes: [DiagnosticReport.CodeGroup]
    let readiness: [DiagnosticReadiness]
    let freezeCauses: [String]
    let supported: [DiagnosticPage]
    let measurements: [DiagnosticMeasurement]
    let exchanges: [Exchange]

    init(_ report: DiagnosticReport, includePrivate: Bool) {
        id = report.id
        started = report.startedAt
        finished = report.finishedAt
        state = report.state
        adapter = includePrivate ? report.adapterName : nil
        protocolName = report.transportProtocol?.rawValue
        source = report.source
        firstObservedCoolantAt = report.firstObservedCoolantAt
        stationaryConfirmed = report.stationaryConfirmedByUser
        modules = report.modules
        codes = report.codes
        readiness = report.readiness
        freezeCauses = report.freezeCauses
        supported = report.pages
        measurements = report.measurements
        exchanges = report.exchanges.map {
            Exchange(command: $0.command, start: $0.startedAt, finish: $0.finishedAt,
                     durationMilliseconds: $0.elapsedMilliseconds, outcome: $0.outcome,
                     rawResponse: includePrivate ? $0.rawResponse : nil, detail: includePrivate ? $0.detail : nil)
        }
    }
}

extension TelemetryArchive {
    func surveys(limit: Int? = nil) throws -> [DiagnosticReport] {
        var rows: [DiagnosticReport] = []
        let clause = limit == nil ? "" : " LIMIT ?"
        try database().query("SELECT payload FROM diagnostic_receipt ORDER BY utc DESC,id DESC" + clause,
                             limit.map { [.integer(Int64($0))] } ?? []) { row in
            if let bytes = DriveSQL.data(row, 0) {
                rows.append(try JSONDecoder().decode(DiagnosticReport.self, from: bytes))
            }
        }
        return rows
    }

    func archivedReadings(trip: Int64, range: ClosedRange<Date>? = nil) throws -> [ArchivedReading] {
        let db = try database()
        var elements: [ArchivedReading] = []
        let rangeFilter = range == nil ? "" : " AND f.utc BETWEEN ? AND ?"
        let arguments: [DriveSQL.Value] = range.map { bounds in [.integer(trip), .time(bounds.lowerBound), .time(bounds.upperBound)] }
            ?? [.integer(trip)]
        try db.query("""
            SELECT f.elapsed,r.utc,r.offset,r.signal,r.value,r.quality,r.bytes
            FROM frame f LEFT JOIN reading r ON r.frame_id=f.id
            WHERE f.trip_id=?
            """ + rangeFilter + " ORDER BY f.elapsed,f.id,r.signal", arguments) { row in
            let elapsed = sqlite3_column_double(row, 0)
            if let signal = DriveSignal(rawValue: UInt8(clamping: sqlite3_column_int(row, 3))),
               let quality = DriveSQL.string(row, 5) {
                elements.append(ArchivedReading(trip: trip, time: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                    elapsedSeconds: max(0, elapsed + sqlite3_column_double(row, 2)), parameter: signal.command,
                    unit: signal.unit, value: DriveSQL.number(row, 4), quality: quality,
                    source: signal == .adapterVoltage ? "adapter" : "ecu", dataHex: DriveSQL.string(row, 6)))
            }
            // A separate query emits one model output per frame, irrespective of its readings.
            if elements.count > 250_000 {
                throw DriveSQL.Failure(message: "Телеметрия слишком велика для одного отчёта. Используйте резервную копию SQLite.")
            }
        }
        try db.query("SELECT utc,elapsed,rate,fuel_method FROM frame f WHERE trip_id=?" + rangeFilter + " ORDER BY elapsed,id",
                     arguments) { row in
            elements.append(ArchivedReading(trip: trip, time: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                elapsedSeconds: sqlite3_column_double(row, 1), parameter: "fuel-estimate", unit: "л/ч",
                value: DriveSQL.number(row, 2), quality: DriveSQL.number(row, 2) == nil ? "unknown" : "experimental",
                source: DriveSQL.string(row, 3) ?? "unavailable", dataHex: nil))
        }
        return elements.sorted { ($0.elapsedSeconds, $0.parameter) < ($1.elapsedSeconds, $1.parameter) }
    }

    func archivedGaps(trip: Int64) throws -> [ArchivedGap] {
        var gaps: [ArchivedGap] = []
        try database().query("SELECT started_utc,resumed_utc,reason FROM gap WHERE trip_id=? ORDER BY id", [.integer(trip)]) { row in
            gaps.append(ArchivedGap(trip: trip,
                start: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                resume: DriveSQL.number(row, 1).map(Date.init(timeIntervalSince1970:)),
                reason: DriveSQL.string(row, 2) ?? "unknown"))
        }
        return gaps
    }

    static func telemetryCSV(_ readings: [ArchivedReading]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = "trip,time_utc,elapsed_seconds,parameter,unit,value,quality,source,pid_bytes_hex"
        var out = header + "\n"
        for row in readings {
            let fields = [String(row.trip), formatter.string(from: row.time), String(row.elapsedSeconds), row.parameter,
                          row.unit, row.value.map { String($0) } ?? "", row.quality, row.source, row.dataHex ?? ""]
            out += fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") + "\n"
        }
        return Data(out.utf8)
    }
}
