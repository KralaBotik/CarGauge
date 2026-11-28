import CSQLite
import Foundation

public struct VoltageReference: Codable, Sendable {
    public let adapter: Double
    public let multimeter: Double
    public let recordedAt: Date
    public var offset: Double { multimeter - adapter }

    public init?(adapter: Double, multimeter: Double, recordedAt: Date = .now) {
        guard (0...30).contains(adapter), (0...30).contains(multimeter), abs(multimeter - adapter) <= 3 else { return nil }
        self.adapter = adapter
        self.multimeter = multimeter
        self.recordedAt = recordedAt
    }
}

public struct HistoryMarker: Identifiable, Codable, Sendable {
    public let id: String
    public let time: Date
    public let elapsed: Double
    public let title: String
    public let kind: String
}

extension TelemetryArchive {
    public func monitoringCheckpoint() throws -> MonitoringCheckpoint? {
        try localState(MonitoringCheckpoint.self, key: "monitoring-v1")
    }

    public func saveMonitoring(_ checkpoint: MonitoringCheckpoint, events: [MonitoringEvent]) throws {
        let db = try database()
        try db.transaction {
            try Self.saveLocalState(checkpoint, key: "monitoring-v1", in: db)
            for event in events {
                try db.run("""
                    INSERT INTO monitoring_event(id,issue,rule,version,utc,trip_id,recovery,payload)
                    VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING
                    """, [.text(event.id.uuidString), .text(event.issueID.uuidString), .text(event.ruleID),
                          .integer(Int64(event.ruleVersion)), .time(event.occurredAt),
                          event.tripID.map(DriveSQL.Value.integer) ?? .null, .integer(event.kind == .recovery ? 1 : 0),
                          .blob(try JSONEncoder().encode(event))])
            }
        }
    }

    public func monitoringEvents(issue: UUID? = nil, limit: Int? = 80) throws -> [MonitoringEvent] {
        let whereClause = issue == nil ? "" : " WHERE issue=?"
        let limitClause = limit == nil ? "" : " LIMIT ?"
        var args: [DriveSQL.Value] = issue.map { [.text($0.uuidString)] } ?? []
        if let limit { args.append(.integer(Int64(max(1, limit)))) }
        var items: [MonitoringEvent] = []
        try database().query("SELECT payload FROM monitoring_event" + whereClause + " ORDER BY utc DESC,rowid DESC" + limitClause, args) { row in
            if let data = DriveSQL.data(row, 0) { items.append(try JSONDecoder().decode(MonitoringEvent.self, from: data)) }
        }
        return items
    }

    public func voltageReference() throws -> VoltageReference? {
        try localState(VoltageReference.self, key: "voltage-reference")
    }

    public func setVoltageReference(_ reference: VoltageReference?) throws {
        let db = try database()
        if let reference {
            try Self.saveLocalState(reference, key: "voltage-reference", in: db)
        } else {
            try db.run("DELETE FROM health_state WHERE key='voltage-reference'", [])
        }
    }

    public func historyMarkers(trip tripID: Int64, includePrivate: Bool = true) throws -> [HistoryMarker] {
        let db = try database()
        let rules = MonitoringProfile.g4fc.rules
        var points: [(String, Date, String, String)] = []
        try db.query("SELECT payload FROM monitoring_event WHERE trip_id=? ORDER BY utc", [.integer(tripID)]) { row in
            guard let data = DriveSQL.data(row, 0) else { return }
            let item = try JSONDecoder().decode(MonitoringEvent.self, from: data)
            let title = rules.first { $0.id == item.ruleID && $0.version == item.ruleVersion }?.title ?? item.ruleID
            points.append((item.id.uuidString, item.occurredAt, title, item.kind.rawValue))
        }
        if let trip = try trip(id: tripID), trip.startedAt <= trip.lastObservation {
            let original = try maintenanceWithoutAttachments()
            let ledger = includePrivate ? original : original.redactedCopy()
            for record in ledger.records {
                guard let date = record.date.value, date >= trip.startedAt, date <= trip.lastObservation else { continue }
                let names = record.work.compactMap { item in ledger.components.first { $0.id == item.componentID }?.title }
                let title = names.joined(separator: ", ") + (record.date.certainty == .approximate ? " · дата примерно" : "")
                points.append((record.id.uuidString, date, title, "servicing"))
            }
        }
        return try points.compactMap { key, date, title, kind in
            let elapsed = try db.scalar("""
                SELECT elapsed FROM frame WHERE trip_id=? ORDER BY ABS(utc-?),id LIMIT 1
                """, [.integer(tripID), .time(date)])
            return elapsed.map { HistoryMarker(id: key, time: date, elapsed: $0, title: title, kind: kind) }
        }
    }
}
