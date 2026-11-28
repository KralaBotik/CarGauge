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

private struct VehicleReportEnvelope: Encodable {
    struct Code: Encodable {
        let observation: DTCFinding
        let description: DTCDescription?
    }

    let schemaVersion = 1
    let profile = "Hyundai Elantra HD 2011 · G4FC 1.6 · МКПП"
    let generated = Date.now
    let coordinates = "not_collected"
    let includesPrivateText: Bool
    let scope: String
    let trips: [RecordedTrip]
    let readings: [ArchivedReading]
    let gaps: [ArchivedGap]
    let codes: [Code]
    let dtcHistory: [DTCHistoryEntry]
    let surveys: [ReportSurvey]
    let rules: [MonitoringRule]
    let events: [MonitoringEvent]
    let maintenance: MaintenanceLedger?
    let usage: MaintenanceUsageDetail?
    let timeline: [HistoryMarker]
    let limitations = [
        "Стандартные OBD-ответы анонимны. Неизвестный результат не означает отсутствия ошибок.",
        "Оценка расхода относится к интервалам со свежими данными. Расход до подключения неизвестен.",
        "Сравнение показаний до и после работ не доказывает причинную связь."
    ]
}

extension TelemetryArchive {
    public func vehicleReport(scope: VehicleReportScope, format: VehicleReportFormat,
                              includePrivate: Bool = false) throws -> Data {
        let db = try database()
        return try db.transaction(readOnly: true) {
            try exportVehicle(scope: scope, format: format, includePrivate: includePrivate)
        }
    }

    private func exportVehicle(scope: VehicleReportScope, format: VehicleReportFormat, includePrivate: Bool) throws -> Data {
        var trips: [RecordedTrip] = []
        var events: [MonitoringEvent] = []
        var sourceSurveys: [DiagnosticReport] = []
        var findings: [DTCFinding] = []
        var history: [DTCHistoryEntry] = []
        var readingRange: ClosedRange<Date>?
        var service: MaintenanceLedger?
        var usage: MaintenanceUsageDetail?
        var reportScope: String
        switch scope {
        case .trip(let selected):
            if let selected, let trip = try trip(id: selected) { trips = [trip] }
            else if selected == nil { trips = try recentTrips(limit: 1) }
            if let trip = trips.first {
                events = try tripMonitoringEvents(trip.id)
                sourceSurveys = try tripSurveys(trip.id)
            }
            reportScope = "trip"
        case .problem(let issue):
            events = try monitoringEvents(issue: issue, limit: nil)
            let ids = Set(events.compactMap(\.tripID)).sorted()
            trips = try ids.compactMap { try trip(id: $0) }
            if let first = events.last?.occurredAt, let last = events.first?.occurredAt {
                readingRange = first.addingTimeInterval(-120)...last.addingTimeInterval(120)
            }
            let codes = Set(events.flatMap(\.relatedDTCs))
            findings = try dtcFindings().filter { codes.contains($0.code) }
            history = try dtcHistory().filter { codes.contains($0.code) }
            for id in ids { sourceSurveys += try tripSurveys(id) }
            reportScope = "problem"
        case .survey:
            sourceSurveys = try surveys(limit: 1)
            reportScope = "survey"
        case .diagnostics:
            sourceSurveys = try surveys()
            findings = try dtcFindings()
            history = try dtcHistory()
            events = try monitoringEvents(limit: nil)
            reportScope = "diagnostics"
        case .servicing:
            let ledger = try maintenanceWithoutAttachments()
            service = includePrivate ? ledger : ledger.redactedCopy()
            if let date = ledger.latestOdometer?.date { usage = try maintenanceUsageDetail(after: date) }
            reportScope = "servicing"
        }

        var samples: [ArchivedReading] = []
        var gaps: [ArchivedGap] = []
        var timeline: [HistoryMarker] = []
        for trip in trips {
            samples += try archivedReadings(trip: trip.id, range: readingRange)
            gaps += try archivedGaps(trip: trip.id)
            timeline += try historyMarkers(trip: trip.id, includePrivate: includePrivate)
        }
        if format == .csv {
            if scope == .survey, let survey = sourceSurveys.first { return Data(survey.csv().utf8) }
            if scope == .diagnostics || scope == .servicing {
                throw DriveSQL.Failure(message: "CSV телеметрии доступен для поездки, проблемы или обследования.")
            }
            return Self.telemetryCSV(samples)
        }
        if format == .txt {
            let stamp = Date.now.ISO8601Format()
            var lines = [
                "CarGauge · Hyundai Elantra HD 2011 / G4FC", stamp,
                "Обследований \(sourceSurveys.count) · поездок \(trips.count) · разрывов \(gaps.count)",
                "Событий мониторинга \(events.count) · результатов по DTC \(findings.count)"
            ]
            for trip in trips {
                let km = trip.distanceKm.map { String($0) + " км" } ?? "пробег неизвестен"
                let fuel = trip.litres.map { String($0) + " л" } ?? "расход неизвестен"
                lines.append("Поездка \(trip.startedAt.ISO8601Format()) · \(km) · оценка топлива \(fuel)")
            }
            for event in events {
                lines.append("\(event.occurredAt.ISO8601Format()) · \(event.ruleID) v\(event.ruleVersion) · \(event.kind.rawValue) · \(event.severity.title)")
            }
            for finding in findings {
                lines.append("\(finding.code) · \(finding.status.title) · последнее обнаружение \(finding.lastSeen.ISO8601Format())")
            }
            if let service {
                lines.append("Записей обслуживания \(service.records.count) · заправок \(service.fills.count)")
            }
            if let survey = sourceSurveys.first, scope == .survey {
                let groups = survey.codes.flatMap { group in
                    group.replyGroups.map { "\(group.status.title) · \($0.joined(separator: ", "))" }
                }
                lines += groups
                lines.append(contentsOf: survey.exchanges.map { "\($0.command) · \($0.outcome.title)" })
            }
            lines.append("Технические результаты относятся к фактически полученным данным.")
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }

        let ruleIDs = Set(events.map(\.ruleID))
        let rules = MonitoringProfile.g4fc.rules.filter { scope == .diagnostics || ruleIDs.contains($0.id) }
        let envelope = VehicleReportEnvelope(includesPrivateText: includePrivate, scope: reportScope,
            trips: trips, readings: samples, gaps: gaps,
            codes: findings.map { .init(observation: $0, description: DTCCatalog.lookup($0.code)) }, dtcHistory: history,
            surveys: sourceSurveys.map { ReportSurvey($0, includePrivate: includePrivate) },
            rules: rules, events: events, maintenance: service, usage: usage, timeline: timeline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func tripMonitoringEvents(_ id: Int64) throws -> [MonitoringEvent] {
        var rows: [MonitoringEvent] = []
        try database().query("SELECT payload FROM monitoring_event WHERE trip_id=? ORDER BY utc", [.integer(id)]) { row in
            if let data = DriveSQL.data(row, 0) { rows.append(try JSONDecoder().decode(MonitoringEvent.self, from: data)) }
        }
        return rows
    }

    private func tripSurveys(_ id: Int64) throws -> [DiagnosticReport] {
        var rows: [DiagnosticReport] = []
        try database().query("SELECT payload FROM diagnostic_receipt WHERE trip_id=? ORDER BY utc", [.integer(id)]) { row in
            if let data = DriveSQL.data(row, 0) { rows.append(try JSONDecoder().decode(DiagnosticReport.self, from: data)) }
        }
        return rows
    }
}
