import CSQLite
import Foundation

extension TelemetryArchive {
    static let healthSchema = """
        CREATE INDEX observed_frame_by_start ON frame(utc-observed) WHERE observed>0;
        CREATE TABLE health_state(key TEXT PRIMARY KEY,payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE monitoring_event(id TEXT PRIMARY KEY,issue TEXT NOT NULL,rule TEXT NOT NULL,version INTEGER NOT NULL,
          utc REAL NOT NULL,trip_id INTEGER REFERENCES trip(id),recovery INTEGER NOT NULL,payload BLOB NOT NULL);
        CREATE INDEX monitoring_by_time ON monitoring_event(utc DESC);
        CREATE INDEX monitoring_by_issue ON monitoring_event(issue,utc);
        CREATE TABLE diagnostic_receipt(id TEXT PRIMARY KEY, utc REAL NOT NULL,trip_id INTEGER REFERENCES trip(id),
          payload BLOB NOT NULL) WITHOUT ROWID;
        CREATE INDEX diagnostic_by_time ON diagnostic_receipt(utc DESC);
        CREATE TABLE dtc_scope(status TEXT PRIMARY KEY,last_valid_utc REAL NOT NULL,framing TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE dtc_finding(status TEXT NOT NULL,code TEXT NOT NULL,first_utc REAL NOT NULL,last_utc REAL NOT NULL,
          absent_utc REAL, appearances INTEGER NOT NULL,last_trip INTEGER REFERENCES trip(id),last_scope TEXT NOT NULL,
          PRIMARY KEY(status,code)) WITHOUT ROWID;
        CREATE TABLE dtc_history(scan TEXT NOT NULL REFERENCES diagnostic_receipt(id),status TEXT NOT NULL,
          code TEXT NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(scan,status,code,kind)) WITHOUT ROWID;
        CREATE TABLE maintenance_entry(kind TEXT NOT NULL,id TEXT NOT NULL,utc REAL,payload BLOB NOT NULL,
          PRIMARY KEY(kind,id)) WITHOUT ROWID;
        CREATE INDEX maintenance_by_time ON maintenance_entry(kind,utc);
        CREATE TABLE maintenance_attachment(record TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,media_type TEXT NOT NULL,
          bytes BLOB NOT NULL,PRIMARY KEY(record,id)) WITHOUT ROWID;
        CREATE TABLE local_notice(id TEXT PRIMARY KEY,created REAL NOT NULL) WITHOUT ROWID;
        """

    public func reserveNotice(_ id: String, at now: Date) throws -> Bool {
        let db = try database()
        return try db.transaction {
            guard try db.scalar("SELECT created FROM local_notice WHERE id=?", [.text(id)]) == nil else { return false }
            try db.run("INSERT INTO local_notice(id,created) VALUES(?,?)", [.text(id), .time(now)])
            return true
        }
    }

    public func releaseNotice(_ id: String) throws {
        try database().run("DELETE FROM local_notice WHERE id=?", [.text(id)])
    }

    public func makeBackup(at destination: URL) throws {
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
            throw DriveSQL.Failure(message: "Для резервной копии требуется новый файл.")
        }
        // Creates a consistent standalone database, including committed WAL data.
        try database().run("VACUUM INTO ?", [.text(destination.path)])
    }

    func localState<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var result: T?
        try database().query("SELECT payload FROM health_state WHERE key=?", [.text(key)]) { row in
            if let bytes = DriveSQL.data(row, 0) { result = try JSONDecoder().decode(type, from: bytes) }
        }
        return result
    }

    static func saveLocalState<T: Encodable>(_ value: T, key: String, in db: DriveSQL) throws {
        try db.run("""
            INSERT INTO health_state(key,payload) VALUES(?,?)
            ON CONFLICT(key) DO UPDATE SET payload=excluded.payload
            """, [.text(key), .blob(try JSONEncoder().encode(value))])
    }
}

public struct DTCFinding: Codable, Sendable, Identifiable {
    public var id: String { "\(status.rawValue).\(code)" }
    public let code: String
    public let status: DiagnosticCodeStatus
    public let firstSeen: Date
    public let lastSeen: Date
    /// A later comparable single positive reply did not report the code.
    public let notReportedAt: Date?
    public let appearances: Int
    public let lastTrip: Int64?
}

public struct DTCHistoryEntry: Codable, Sendable {
    public let scan: String
    public let timestamp: Date
    public let status: DiagnosticCodeStatus
    public let code: String
    public let kind: String
    public let tripID: Int64?
}

extension TelemetryArchive {
    public func saveDiagnostic(_ report: DiagnosticReport, owner: UUID? = nil) throws {
        let db = try database()
        let trip = currentTripID(owner: owner).map(DriveSQL.Value.integer) ?? .null
        try db.transaction { try Self.storeDiagnostic(report, trip: trip, db: db) }
    }

    static func importV1DiagnosticReceipts(_ db: DriveSQL) throws {
        struct LegacyEnvelope: Decodable { let survey: DiagnosticReport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try db.query("""
            SELECT payload,trip_id FROM event WHERE kind IN ('automatic_dtc','manual_survey') ORDER BY utc,id
            """) { row in
            guard let payload = DriveSQL.string(row, 0),
                  let envelope = try? decoder.decode(LegacyEnvelope.self, from: Data(payload.utf8)) else { return }
            let trip: DriveSQL.Value = sqlite3_column_type(row, 1) == SQLITE_NULL
                ? .null : .integer(sqlite3_column_int64(row, 1))
            try storeDiagnostic(envelope.survey, trip: trip, db: db)
        }
    }

    private static func storeDiagnostic(_ report: DiagnosticReport, trip: DriveSQL.Value, db: DriveSQL) throws {
        let scan = report.id.uuidString
        guard try db.scalar("SELECT 1 FROM diagnostic_receipt WHERE id=?", [.text(scan)]) == nil else { return }
        try db.run("INSERT INTO diagnostic_receipt(id,utc,trip_id,payload) VALUES(?,?,?,?)",
                   [.text(scan), .time(report.startedAt), trip, .blob(try JSONEncoder().encode(report))])
        guard report.source == "vehicle" || report.source == "test_fixture",
              let protocolValue = report.transportProtocol else { return }
        for group in report.codes {
            guard !group.replyGroups.isEmpty else { continue }
            try recordCodes(group, report: report, framing: protocolValue.rawValue, trip: trip, db: db)
        }
    }

    private static func recordCodes(_ group: DiagnosticReport.CodeGroup, report: DiagnosticReport, framing: String,
                             trip: DriveSQL.Value, db: DriveSQL) throws {
        let status = group.status.rawValue
        let scan = report.id.uuidString
        let time = report.startedAt.timeIntervalSince1970
        var older: (Double, String)?
        try db.query("SELECT last_valid_utc,framing FROM dtc_scope WHERE status=?", [.text(status)]) { row in
            if let mode = DriveSQL.string(row, 1) { older = (sqlite3_column_double(row, 0), mode) }
        }
        guard older.map({ time >= $0.0 }) ?? true else { return }
        let codes = Set(group.replyGroups.flatMap { $0 })
        let coverage = "\(framing)#\(group.replyGroups.count)"
        var previous: [String: (absent: Bool, coverage: String)] = [:]
        try db.query("SELECT code,absent_utc,last_scope FROM dtc_finding WHERE status=?", [.text(status)]) { row in
            if let code = DriveSQL.string(row, 0), let scope = DriveSQL.string(row, 2) {
                previous[code] = (DriveSQL.number(row, 1) != nil, scope)
            }
        }
        let observedScope = report.state == .completed ? coverage : "partial"
        for code in codes.sorted() {
            let kind = previous[code].map { $0.absent ? "reappeared" : "seen" } ?? "first_seen"
            try db.run("""
                INSERT INTO dtc_finding(status,code,first_utc,last_utc,appearances,last_trip,last_scope) VALUES(?,?,?,?,1,?,?)
                ON CONFLICT(status,code) DO UPDATE SET
                last_utc=excluded.last_utc,appearances=dtc_finding.appearances+(dtc_finding.absent_utc IS NOT NULL),
                absent_utc=NULL,last_trip=excluded.last_trip,last_scope=excluded.last_scope
                """, [.text(status), .text(code), .real(time), .real(time), trip, .text(observedScope)])
            try db.run("INSERT INTO dtc_history(scan,status,code,kind) VALUES(?,?,?,?)",
                       [.text(scan), .text(status), .text(code), .text(kind)])
        }
        // Never interpret silence or an ambiguous collection of respondents as a recovery.
        if group.replyGroups.count == 1, report.state == .completed, older?.1 == coverage {
            for (code, finding) in previous where !finding.absent && finding.coverage == coverage && !codes.contains(code) {
                try db.run("UPDATE dtc_finding SET absent_utc=? WHERE status=? AND code=?",
                           [.real(time), .text(status), .text(code)])
                try db.run("INSERT INTO dtc_history(scan,status,code,kind) VALUES(?,?,?,?)",
                           [.text(scan), .text(status), .text(code), .text("not_reported")])
            }
        }
        try db.run("""
            INSERT INTO dtc_scope(status,last_valid_utc,framing) VALUES(?,?,?)
            ON CONFLICT(status) DO UPDATE SET last_valid_utc=excluded.last_valid_utc,framing=excluded.framing
            """, [.text(status), .real(time), .text(report.state == .completed ? coverage : "partial")])
    }

    public func dtcFindings() throws -> [DTCFinding] {
        var result: [DTCFinding] = []
        try database().query("""
            SELECT code,status,first_utc,last_utc,absent_utc,appearances,last_trip FROM dtc_finding
            ORDER BY absent_utc IS NOT NULL,last_utc DESC,code,status
            """) { row in
            guard let code = DriveSQL.string(row, 0), let key = DriveSQL.string(row, 1),
                  let status = DiagnosticCodeStatus(rawValue: key) else { return }
            result.append(DTCFinding(code: code, status: status,
                firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                notReportedAt: DriveSQL.number(row, 4).map(Date.init(timeIntervalSince1970:)),
                appearances: Int(sqlite3_column_int64(row, 5)),
                lastTrip: sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 6)))
        }
        return result
    }

    public func dtcHistory(code: String? = nil) throws -> [DTCHistoryEntry] {
        var result: [DTCHistoryEntry] = []
        let clause = code == nil ? "" : " WHERE e.code=?"
        try database().query("""
            SELECT e.scan,r.utc,e.status,e.code,e.kind,r.trip_id
            FROM dtc_history e JOIN diagnostic_receipt r ON r.id=e.scan
            """ + clause + " ORDER BY r.utc DESC,e.status,e.code", code.map { [.text($0)] } ?? []) { row in
            guard let scan = DriveSQL.string(row, 0), let statusText = DriveSQL.string(row, 2),
                  let status = DiagnosticCodeStatus(rawValue: statusText), let code = DriveSQL.string(row, 3),
                  let kind = DriveSQL.string(row, 4) else { return }
            result.append(DTCHistoryEntry(scan: scan, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                status: status, code: code, kind: kind,
                tripID: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 5)))
        }
        return result
    }

    public func recordedSurvey(_ id: String) throws -> DiagnosticReport? {
        var survey: DiagnosticReport?
        try database().query("SELECT payload FROM diagnostic_receipt WHERE id=?", [.text(id)]) { row in
            if let bytes = DriveSQL.data(row, 0) { survey = try JSONDecoder().decode(DiagnosticReport.self, from: bytes) }
        }
        return survey
    }

    public func lastSurvey() throws -> DiagnosticReport? {
        var survey: DiagnosticReport?
        try database().query("SELECT payload FROM diagnostic_receipt ORDER BY utc DESC,id DESC LIMIT 1") { row in
            if let bytes = DriveSQL.data(row, 0) { survey = try JSONDecoder().decode(DiagnosticReport.self, from: bytes) }
        }
        return survey
    }
}
