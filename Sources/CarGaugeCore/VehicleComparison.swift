import CSQLite
import Foundation

public struct VehicleComparison: Sendable, Identifiable {
    public var id: UInt8 { signal.rawValue }
    public let signal: DriveSignal
    public let context: String
    public let before: Double
    public let after: Double
    public let beforeTrips: Int
    public let afterTrips: Int
    public let beforeTripID: Int64?
    public let afterTripID: Int64?
}

public struct FuelTripComparison: Sendable {
    public let older: RecordedTrip
    public let newer: RecordedTrip
    public let meanSpeedDifference: Double
    public let commonCalibration: Double
}

extension TelemetryArchive {
    /// Only recorded warm idle within the same measured ambient and load class.
    public func compareServicing(at date: Date, signals: [DriveSignal]) throws -> [VehicleComparison] {
        let db = try database()
        let radius: TimeInterval = 30 * 86400
        var result: [VehicleComparison] = []
        for signal in Set(signals).sorted(by: { $0.rawValue < $1.rawValue }) {
            var buckets: [String: [(before: Bool, trip: Int64, value: Double)]] = [:]
            try db.query("""
                SELECT t.id,t.last_utc<?,AVG(s.value),CAST(a.value/10 AS INTEGER),CAST(l.value/10 AS INTEGER),COUNT(s.value)
                FROM trip t JOIN frame f ON f.trip_id=t.id JOIN reading s ON s.frame_id=f.id
                  JOIN reading c ON c.frame_id=f.id AND c.signal=5 AND c.quality='received'
                  JOIN reading a ON a.frame_id=(SELECT af.id FROM frame af JOIN reading ar ON ar.frame_id=af.id
                      WHERE af.trip_id=t.id AND af.elapsed<=f.elapsed AND af.elapsed>=f.elapsed-45
                      AND ar.signal=70 AND ar.quality='received' ORDER BY af.elapsed DESC LIMIT 1) AND a.signal=70
                  JOIN reading l ON l.frame_id=(SELECT lf.id FROM frame lf JOIN reading lr ON lr.frame_id=lf.id
                      WHERE lf.trip_id=t.id AND lf.elapsed<=f.elapsed AND lf.elapsed>=f.elapsed-20
                      AND lr.signal=4 AND lr.quality='received' ORDER BY lf.elapsed DESC LIMIT 1) AND l.signal=4
                WHERE (t.last_utc<? OR t.started_utc>?) AND t.started_utc>=? AND t.last_utc<=?
                  AND f.speed=0 AND f.rpm>0 AND c.value BETWEEN 80 AND 105 AND s.signal=? AND s.quality='received'
                  AND NOT EXISTS (SELECT 1 FROM event e WHERE e.trip_id=t.id AND e.kind='wall_clock_change')
                GROUP BY t.id,CAST(a.value/10 AS INTEGER),CAST(l.value/10 AS INTEGER)
                HAVING COUNT(s.value)>=5 ORDER BY t.id
                """, [.time(date), .time(date), .time(date), .time(date.addingTimeInterval(-radius)),
                      .time(date.addingTimeInterval(radius)), .integer(Int64(signal.rawValue))]) { row in
                guard let value = DriveSQL.number(row, 2) else { return }
                let ambient = sqlite3_column_int(row, 3) * 10
                let load = sqlite3_column_int(row, 4) * 10
                let key = "Прогретый холостой ход · класс воздуха \(ambient) °C · класс нагрузки \(load)%"
                buckets[key, default: []].append((sqlite3_column_int(row, 1) != 0, sqlite3_column_int64(row, 0), value))
            }
            let matched = buckets.sorted { $0.key < $1.key }.filter { _, bucket in
                bucket.filter(\.before).count >= 2 && bucket.filter { !$0.before }.count >= 2
            }.max { $0.value.count < $1.value.count }
            guard let matched else { continue }
            let before = matched.value.filter(\.before)
            let after = matched.value.filter { !$0.before }
            result.append(VehicleComparison(signal: signal, context: matched.key,
                before: Self.medianValue(before.map(\.value)), after: Self.medianValue(after.map(\.value)),
                beforeTrips: before.count, afterTrips: after.count, beforeTripID: before.last?.trip, afterTripID: after.first?.trip))
        }
        return result
    }

    /// Report-only comparison. This never opens a monitoring problem.
    public func comparableFuelTrips() throws -> FuelTripComparison? {
        let db = try database()
        var options: [(RecordedTrip, Double, Double, Double)] = []
        for trip in try recentTrips(limit: 12) {
            guard trip.finishReason == "engine_stopped", trip.observedEngineSeconds > 0,
                  trip.fuelSeconds / trip.observedEngineSeconds >= 0.90, let km = trip.distanceKm, km > 0,
                  trip.averageLitresPer100km != nil else { continue }
            let speed = 3600 * km / max(trip.distanceSeconds, 1)
            var calibration: Double?
            var ambient: Double?
            try db.query("""
                SELECT MIN(f.calibration),MAX(f.calibration),AVG(r.value) FROM frame f
                LEFT JOIN reading r ON r.frame_id=f.id AND r.signal=70 AND r.quality='received'
                WHERE f.trip_id=?
                """, [.integer(trip.id)]) { row in
                if let minimum = DriveSQL.number(row, 0), minimum == DriveSQL.number(row, 1) { calibration = minimum }
                ambient = DriveSQL.number(row, 2)
            }
            if let calibration, let ambient { options.append((trip, speed, calibration, ambient)) }
        }
        guard let latest = options.first,
              let older = options.dropFirst().first(where: { item in
                  item.2 == latest.2 && abs(item.3 - latest.3) <= 5 && abs(item.1 - latest.1) <= 8
              }) else { return nil }
        return FuelTripComparison(older: older.0, newer: latest.0,
                                  meanSpeedDifference: latest.1 - older.1, commonCalibration: latest.2)
    }

    private static func medianValue(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2) ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
    }
}
