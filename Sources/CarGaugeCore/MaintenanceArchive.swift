import CSQLite
import Foundation

public struct MaintenanceUsageDetail: Codable, Sendable {
    public let kilometres: Double?
    public let observedSeconds: Double?
    public let additionalRunTimeSeconds: Double?
}

extension TelemetryArchive: MaintenanceStore {
    public func readMaintenance() throws -> MaintenanceLedger {
        try Self.readLedger(database(), includeAttachments: true)
    }

    public func maintenanceWithoutAttachments() throws -> MaintenanceLedger {
        try Self.readLedger(database(), includeAttachments: false)
    }

    public func applyMaintenance(_ change: MaintenanceChange) throws -> MaintenanceLedger {
        let db = try database()
        return try db.transaction {
            var ledger = try Self.readLedger(db, includeAttachments: true)
            try ledger.apply(change)
            switch change {
            case .saveRecord(var record):
                let attachments = record.attachments
                record.attachments = []
                let key = record.id.uuidString
                try Self.put(record, kind: "work", id: key, date: record.date.value, db: db)
                try db.run("DELETE FROM maintenance_attachment WHERE record=?", [.text(key)])
                for item in attachments {
                    try db.run("INSERT INTO maintenance_attachment(record,id,name,media_type,bytes) VALUES(?,?,?,?,?)",
                        [.text(key), .text(item.id.uuidString), .text(item.filename), .text(item.mediaType), .blob(item.data)])
                }
            case .deleteRecord(let id):
                try db.run("DELETE FROM maintenance_attachment WHERE record=?", [.text(id.uuidString)])
                try Self.remove(kind: "work", id: id, db: db)
            case .saveOdometer(let item):
                try Self.put(item, kind: "odometer", id: item.id.uuidString, date: item.date, db: db)
            case .deleteOdometer(let id):
                try Self.remove(kind: "odometer", id: id, db: db)
            case .saveFill(let item):
                try Self.put(item, kind: "fuel", id: item.id.uuidString, date: item.date.value, db: db)
            case .deleteFill(let id):
                try Self.remove(kind: "fuel", id: id, db: db)
            case .saveComponent(let item):
                try Self.put(item, kind: "component", id: item.id, db: db)
            case .saveRule(let item):
                try Self.put(item, kind: "rule", id: item.id.uuidString, db: db)
            case .deleteRule(let id):
                try Self.remove(kind: "rule", id: id, db: db)
            case .settings(let settings):
                try Self.put(settings, kind: "settings", id: "default", db: db)
            }
            return ledger
        }
    }

    private static func readLedger(_ db: DriveSQL, includeAttachments: Bool) throws -> MaintenanceLedger {
        let decoder = JSONDecoder()
        var result = MaintenanceLedger()
        try db.query("SELECT kind,payload FROM maintenance_entry ORDER BY utc,id") { row in
            guard let kind = DriveSQL.string(row, 0), let data = DriveSQL.data(row, 1) else { return }
            switch kind {
            case "work": result.records.append(try decoder.decode(MaintenanceRecord.self, from: data))
            case "odometer": result.odometers.append(try decoder.decode(MaintenanceOdometer.self, from: data))
            case "fuel": result.fills.append(try decoder.decode(MaintenanceFill.self, from: data))
            case "component": result.customComponents.append(try decoder.decode(MaintenanceComponent.self, from: data))
            case "rule": result.rules.append(try decoder.decode(MaintenanceRule.self, from: data))
            case "settings": result.settings = try decoder.decode(MaintenanceSettings.self, from: data)
            default: break
            }
        }
        if includeAttachments {
            var media: [UUID: [MaintenanceAttachment]] = [:]
            try db.query("SELECT record,id,name,media_type,bytes FROM maintenance_attachment ORDER BY id") { row in
                guard let recordKey = DriveSQL.string(row, 0), let record = UUID(uuidString: recordKey),
                      let idValue = DriveSQL.string(row, 1), let id = UUID(uuidString: idValue),
                      let name = DriveSQL.string(row, 2), let type = DriveSQL.string(row, 3),
                      let bytes = DriveSQL.data(row, 4) else { return }
                media[record, default: []].append(.init(id: id, filename: name, mediaType: type, data: bytes))
            }
            for i in result.records.indices { result.records[i].attachments = media[result.records[i].id] ?? [] }
        }
        return result
    }

    private static func put<T: Encodable>(_ payload: T, kind: String, id: String, date: Date? = nil, db: DriveSQL) throws {
        try db.run("""
            INSERT INTO maintenance_entry(kind,id,utc,payload) VALUES(?,?,?,?)
            ON CONFLICT(kind,id) DO UPDATE SET utc=excluded.utc,payload=excluded.payload
            """, [.text(kind), .text(id), .time(date), .blob(try JSONEncoder().encode(payload))])
    }

    private static func remove(kind: String, id: UUID, db: DriveSQL) throws {
        try db.run("DELETE FROM maintenance_entry WHERE kind=? AND id=?", [.text(kind), .text(id.uuidString)])
    }

    public func observedMaintenanceUsage(after date: Date) throws -> MaintenanceUsage {
        let details = try maintenanceUsageDetail(after: date)
        return .init(distanceKm: details.kilometres, engineHours: details.observedSeconds.map { $0 / 3600 })
    }

    public func maintenanceUsageDetail(after date: Date) throws -> MaintenanceUsageDetail {
        let db = try database()
        let lower = date.timeIntervalSince1970
        let scope = """
            AND NOT EXISTS(SELECT 1 FROM event e WHERE e.trip_id=t.id AND e.kind='wall_clock_change')
            """
        var inferred: [ClosedRange<Double>] = []
        try db.query("""
            SELECT engine_start_utc,started_utc FROM trip t
            WHERE engine_start_utc<started_utc AND started_utc>?
            """ + scope, [.real(lower)]) { row in
            let start = sqlite3_column_double(row, 0)
            let end = sqlite3_column_double(row, 1)
            if start.isFinite, end.isFinite, end - start <= 65535 {
                inferred.append(max(lower, start)...end)
            }
        }
        var observed: [ClosedRange<Double>] = []
        var elapsed: Double?
        var distance: Double?
        try db.query("""
            SELECT f.utc,f.observed,f.km FROM frame f JOIN trip t ON t.id=f.trip_id
            WHERE f.observed>0 AND f.utc-f.observed>=?
            """ + scope + " ORDER BY f.utc-f.observed", [.real(lower)]) { row in
            let end = sqlite3_column_double(row, 0)
            let span = sqlite3_column_double(row, 1)
            if end.isFinite, span.isFinite, span > 0 {
                if !inferred.isEmpty {
                    let start = end - span
                    if let last = observed.last, start <= last.upperBound {
                        observed[observed.count - 1] = last.lowerBound...max(last.upperBound, end)
                    } else {
                        observed.append(start...end)
                    }
                }
                elapsed = (elapsed ?? 0) + span
            }
            if let km = DriveSQL.number(row, 2) { distance = (distance ?? 0) + km }
        }
        let extra = inferred.isEmpty ? nil :
            max(0, Self.intervalUnionSeconds(observed + inferred) - Self.intervalUnionSeconds(observed))
        return MaintenanceUsageDetail(kilometres: distance, observedSeconds: elapsed, additionalRunTimeSeconds: extra)
    }

    static func intervalUnionSeconds(_ ranges: [ClosedRange<Double>]) -> Double {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard var active = sorted.first else { return 0 }
        var total = 0.0
        for range in sorted.dropFirst() {
            if range.lowerBound > active.upperBound {
                total += active.upperBound - active.lowerBound
                active = range
            } else {
                active = active.lowerBound...max(active.upperBound, range.upperBound)
            }
        }
        return total + active.upperBound - active.lowerBound
    }
}
