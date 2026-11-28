import CSQLite
import Foundation

/// Opens a single connection on its actor. A frame, its raw samples, coverage,
/// and trip boundary are written in the same transaction.
public actor TelemetryArchive {
    private struct Active {
        let owner: UUID
        let id: Int64
        let origin: Double
        var previous: TripFrame
        var writeGap = false
    }

    private struct PendingEnd {
        let id: Int64
        let lastObservation: Date
        let reason: String
    }

    private let url: URL
    private var connection: DriveSQL?
    private var active: Active?
    private var pendingEnd: PendingEnd?
    // Reject older session tasks that resume after stop or replacement.
    private var endedOwners: [UUID] = []

    public init(url: URL) { self.url = url }

    func database() throws -> DriveSQL {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try DriveSQL(url: url)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        let version = try db.scalar("PRAGMA user_version") ?? 0
        guard (0...2).contains(version) else { throw DriveSQL.Failure(message: "Неподдерживаемая версия локальной истории.") }
        try db.transaction {
            if version == 0 { try db.execute(Self.schemaV1) }
            if version < 2 {
                try db.execute(Self.healthSchema)
                try Self.importV1DiagnosticReceipts(db)
                try db.execute("PRAGMA user_version=2")
            }
            try db.execute("UPDATE trip SET finish = 'app_interrupted' WHERE finish IS NULL")
            try db.execute("""
                INSERT INTO gap(trip_id, started_utc, reason)
                SELECT id, last_utc, finish FROM trip
                WHERE finish = 'app_interrupted'
                AND NOT EXISTS (SELECT 1 FROM gap WHERE gap.trip_id = trip.id AND reason = 'app_interrupted')
                """)
        }
        connection = db
        return db
    }

    @discardableResult public func record(owner: UUID, frame: TripFrame) throws -> Int64? {
        guard !endedOwners.contains(owner), frame.monotonic.isFinite else { return nil }
        let db = try database()
        try flushPendingEnd(database: db)
        if let active {
            guard active.owner == owner else { throw DriveSQL.Failure(message: "Переход между сеансами записи.") }
            guard frame.monotonic > active.previous.monotonic else { return active.id }
            let elapsed = frame.monotonic - active.previous.monotonic
            let stopped = frame.rpm == 0 && active.previous.rpm == 0 && elapsed <= TripInterval.maximumGap
            let interrupted = active.writeGap || elapsed > TripInterval.maximumGap || frame.rpm == nil
                || active.previous.rpm == nil || (active.previous.rpm == 0 && frame.rpm != 0)
            let delta = interrupted ? nil : TripInterval.between(active.previous, frame)
            do {
                try db.transaction {
                    try Self.saveFrame(frame, id: active.id, elapsed: frame.monotonic - active.origin,
                                       delta: delta, interrupted: interrupted, database: db)
                    if abs(frame.timestamp.timeIntervalSince(active.previous.timestamp) - elapsed) > 2 {
                        try db.run("INSERT INTO event(trip_id,utc,kind,payload) VALUES (?,?,?,?)",
                                   [.integer(active.id), .time(frame.timestamp), .text("wall_clock_change"), .text("UTC discontinuity")])
                    }
                    if interrupted {
                        try db.run("INSERT INTO gap(trip_id,started_utc,resumed_utc,reason) VALUES (?,?,?,?)",
                                   [.integer(active.id), .time(active.previous.timestamp), .time(frame.timestamp), .text("coverage")])
                    }
                    try db.run("""
                        UPDATE trip SET last_utc=?, engine_start_utc=COALESCE(engine_start_utc,?),
                            finish=CASE WHEN ? THEN 'engine_stopped' ELSE finish END WHERE id=?
                        """, [.time(frame.timestamp), .time(frame.estimatedEngineStart), .integer(stopped ? 1 : 0), .integer(active.id)])
                }
            } catch {
                self.active?.writeGap = true
                throw error
            }
            self.active = stopped ? nil : Active(owner: owner, id: active.id, origin: active.origin, previous: frame)
            return active.id
        } else if frame.rpm != 0 && (frame.rpm != nil ||
                    frame.readings.contains { $0.signal == .coolant && $0.quality == .received }) {
            let id = try db.transaction {
                try db.run("INSERT INTO trip(owner,started_utc,last_utc,engine_start_utc,connected_utc) VALUES (?,?,?,?,?)",
                    [.text(owner.uuidString), .time(frame.timestamp), .time(frame.timestamp),
                     .time(frame.estimatedEngineStart), .time(frame.connectedAt)])
                let id = db.lastID
                try Self.saveFrame(frame, id: id, elapsed: 0, delta: nil, interrupted: false, database: db)
                try db.run("UPDATE gap SET resumed_utc=? WHERE resumed_utc IS NULL AND trip_id != ?",
                           [.time(frame.timestamp), .integer(id)])
                return id
            }
            active = Active(owner: owner, id: id, origin: frame.monotonic, previous: frame)
            return id
        }
        return nil
    }

    func currentTripID(owner: UUID?) -> Int64? {
        active.flatMap { $0.owner == owner ? $0.id : nil }
    }

    public func end(owner: UUID, reason: String, mayResume: Bool = false) throws {
        if !mayResume && !endedOwners.contains(owner) {
            endedOwners.append(owner)
            if endedOwners.count > 64 { endedOwners.removeFirst() }
        }
        if let active, active.owner == owner {
            // Cut the integration cursor before I/O. The next recording attempt retries
            // the pending close even if a write lock or a full disk prevented this call.
            let reliableReason = active.writeGap ? "storage_interrupted" : reason
            pendingEnd = PendingEnd(id: active.id, lastObservation: active.previous.timestamp, reason: reliableReason)
            self.active = nil
        }
        if pendingEnd != nil { try flushPendingEnd(database: database()) }
    }

    private func flushPendingEnd(database db: DriveSQL) throws {
        guard let pendingEnd else { return }
        try db.transaction {
            try db.run("UPDATE trip SET finish=? WHERE id=?", [.text(pendingEnd.reason), .integer(pendingEnd.id)])
            if pendingEnd.reason != "engine_stopped" {
                try db.run("INSERT INTO gap(trip_id,started_utc,reason) VALUES (?,?,?)",
                           [.integer(pendingEnd.id), .time(pendingEnd.lastObservation), .text(pendingEnd.reason)])
            }
        }
        self.pendingEnd = nil
    }

    public func addEvent(kind: String, payload: String, timestamp: Date = .now,
                         owner: UUID? = nil, summary: String? = nil) throws {
        let db = try database()
        let trip = active.flatMap { owner == $0.owner ? .integer($0.id) : nil } ?? DriveSQL.Value.null
        try db.transaction {
            let query = "INSERT INTO event(trip_id,utc,kind,payload) VALUES (?,?,?,?)"
            try db.run(query, [trip, .time(timestamp), .text(kind), .text(payload)])
            if let summary { try db.run(query, [trip, .time(timestamp), .text("dtc_summary"), .text(summary)]) }
        }
    }

    public func recentEvents(limit: Int = 20) throws -> [String] {
        var events: [String] = []
        try database().query("SELECT payload FROM event WHERE kind = 'dtc_summary' ORDER BY id DESC LIMIT ?",
                             [.integer(Int64(max(1, min(limit, 100))))]) { row in
            if let text = DriveSQL.string(row, 0) { events.append(text) }
        }
        return events
    }

    public func recentTrips(before id: Int64? = nil, limit: Int = 50) throws -> [RecordedTrip] {
        try trips(condition: "t.id < ?", bindings: [.integer(id ?? Int64.max), .integer(Int64(max(1, min(limit, 100))))])
    }

    public func trip(id: Int64) throws -> RecordedTrip? {
        try trips(condition: "t.id = ?", bindings: [.integer(id), .integer(1)]).first
    }

    public func detail(tripID: Int64, channels: Set<DriveSignal>) throws -> (trip: RecordedTrip, plot: TripPlot)? {
        // This actor owns the sole connection. Without an await, both reads see the same revision.
        guard let trip = try trip(id: tripID) else { return nil }
        return (trip, try plot(tripID: tripID, channels: channels))
    }

    private func trips(condition: String, bindings: [DriveSQL.Value]) throws -> [RecordedTrip] {
        let db = try database()
        var trips: [RecordedTrip] = []
        try db.query("""
            SELECT t.id,t.started_utc,t.last_utc,t.finish,t.engine_start_utc,MAX(f.elapsed),
              SUM(f.observed),SUM(f.km),SUM(CASE WHEN f.km IS NOT NULL THEN f.observed ELSE 0 END),
              SUM(f.litres),SUM(CASE WHEN f.litres IS NOT NULL THEN f.observed ELSE 0 END),
              100*SUM(f.paired_litres)/NULLIF(SUM(f.paired_km),0),SUM(f.idle),SUM(f.idle_litres),MAX(f.speed),
              t.connected_utc
            FROM (SELECT * FROM trip t WHERE \(condition) ORDER BY id DESC LIMIT ?) t
              JOIN frame f ON f.trip_id=t.id GROUP BY t.id ORDER BY t.id DESC
            """, bindings) { row in
            trips.append(RecordedTrip(id: sqlite3_column_int64(row, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                lastObservation: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                finishReason: DriveSQL.string(row, 3), elapsedSeconds: sqlite3_column_double(row, 5),
                estimatedEngineStart: DriveSQL.number(row, 4).map(Date.init(timeIntervalSince1970:)),
                connectedAt: DriveSQL.number(row, 15).map(Date.init(timeIntervalSince1970:)),
                observedEngineSeconds: sqlite3_column_double(row, 6), distanceKm: DriveSQL.number(row, 7),
                distanceSeconds: sqlite3_column_double(row, 8), litres: DriveSQL.number(row, 9),
                fuelSeconds: sqlite3_column_double(row, 10), averageLitresPer100km: DriveSQL.number(row, 11),
                idleSeconds: sqlite3_column_double(row, 12), idleLitres: DriveSQL.number(row, 13),
                peakSpeed: DriveSQL.number(row, 14)))
        }
        return trips
    }

    public func plot(tripID: Int64, channels: Set<DriveSignal>) throws -> TripPlot {
        let db = try database()
        var series: [DriveSignal: [TripPlot.Point]] = [:]
        var fuel: [TripPlot.Point] = []
        var elapsed = 0.0
        var last: [DriveSignal: (time: Double, segment: Int, epoch: Int)] = [:]
        var chartEpoch = 0
        var fuelSegment = 0
        var lastFuel: Double?
        var lastFuelExpiry: Double?
        var openFrame: Int64?
        return try db.transaction(readOnly: true) {
            try db.query("""
                SELECT f.id,f.elapsed,f.rate,r.signal,r.value,r.quality,r.offset,f.discontinuous,f.fuel_valid_for FROM frame f
                  LEFT JOIN reading r ON r.frame_id=f.id WHERE f.trip_id=? ORDER BY f.elapsed,f.id
                """, [.integer(tripID)]) { row in
                let id = sqlite3_column_int64(row, 0)
                let time = sqlite3_column_double(row, 1)
                elapsed = max(elapsed, time)
                if openFrame != id {
                    openFrame = id
                    if sqlite3_column_int(row, 7) != 0 {
                        chartEpoch += 1
                        lastFuel = nil
                    }
                    if let rate = DriveSQL.number(row, 2) {
                        if (lastFuel.map { time - $0 > TripInterval.maximumGap } ?? true)
                            || (lastFuelExpiry.map { time > $0 } ?? false) { fuelSegment += 1 }
                        fuel.append(.init(id: id, time: time, value: rate, segment: fuelSegment))
                        lastFuel = time
                        lastFuelExpiry = DriveSQL.number(row, 8).map { time + $0 }
                    } else {
                        lastFuel = nil
                        lastFuelExpiry = nil
                    }
                }
                guard let signal = DriveSignal(rawValue: UInt8(clamping: sqlite3_column_int(row, 3))),
                      channels.contains(signal) else { return }
                let sampleTime = max(0, time + sqlite3_column_double(row, 6))
                let previous = last[signal]
                let horizon = max(TripInterval.maximumGap, signal.cadence * 2.5)
                let joins = previous.map { sampleTime - $0.time <= horizon && $0.epoch == chartEpoch } ?? false
                let segment = (previous?.segment ?? 0) + (joins ? 0 : 1)
                guard DriveSQL.string(row, 5) == DriveReading.Quality.received.rawValue,
                      let value = DriveSQL.number(row, 4) else {
                    last[signal] = (-Double.infinity, segment, chartEpoch)
                    return
                }
                last[signal] = (sampleTime, segment, chartEpoch)
                series[signal, default: []].append(.init(id: id, time: sampleTime, value: value, segment: segment))
            }
            let gaps = try db.scalar("SELECT COUNT(*) FROM gap WHERE trip_id=?", [.integer(tripID)]) ?? 0
            return TripPlot(seconds: elapsed, series: series, fuel: fuel, gaps: Int(gaps))
        }
    }

    public func databaseSize() throws -> Int64 {
        _ = try database()
        return ["", "-wal", "-shm"].reduce(0) { sum, suffix in
            let path = url.path + suffix
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    public func calibration() throws -> FuelCalibrationState {
        let db = try database()
        let epoch = try Self.calibrationEpoch(db)
        let factor = try db.scalar("SELECT SUM(litres)/NULLIF(SUM(base_litres),0) FROM fill WHERE id>?", [.integer(epoch)]) ?? 1
        guard factor.isFinite, factor > 0 else { throw FuelCalibrationError.invalid }
        let count = try db.scalar("SELECT COUNT(*) FROM fill WHERE id>?", [.integer(epoch)]) ?? 0
        var start: (Double, Date)?
        try db.query("SELECT odometer,utc FROM fill_start WHERE id=1") { row in
            start = (sqlite3_column_double(row, 0), Date(timeIntervalSince1970: sqlite3_column_double(row, 1)))
        }
        return FuelCalibrationState(factor: factor, initialOdometer: start?.0, initialDate: start?.1, matchedFills: Int(count))
    }

    public func resetCalibration() throws -> FuelCalibrationState {
        let db = try database()
        guard active == nil, pendingEnd == nil else { throw FuelCalibrationError.activeEngine }
        try db.transaction {
            let lastID = Int64(try db.scalar("SELECT COALESCE(MAX(id),0) FROM fill") ?? 0)
            try Self.saveLocalState(lastID, key: "fuel-calibration-epoch", in: db)
            try db.run("DELETE FROM fill_start WHERE id=1", [])
        }
        return try calibration()
    }

    private static func calibrationEpoch(_ db: DriveSQL) throws -> Int64 {
        try db.scalar("SELECT CAST(CAST(payload AS TEXT) AS INTEGER) FROM health_state WHERE key='fuel-calibration-epoch'")
            .map(Int64.init) ?? 0
    }

    public func startCalibration(odometer: Double, at date: Date = .now) throws -> FuelCalibrationState {
        guard try calibration().initialOdometer == nil else { throw FuelCalibrationError.alreadyStarted }
        return try restartCalibration(odometer: odometer, at: date)
    }

    public func restartCalibration(odometer: Double, at date: Date = .now) throws -> FuelCalibrationState {
        guard odometer.isFinite, odometer >= 0 else { throw FuelCalibrationError.invalid }
        guard active == nil, pendingEnd == nil else { throw FuelCalibrationError.activeEngine }
        try database().run("""
            INSERT INTO fill_start(id,odometer,utc,trip_cursor)
            VALUES(1,?,?,(SELECT COALESCE(MAX(id),0) FROM trip))
            ON CONFLICT(id) DO UPDATE SET odometer=excluded.odometer,utc=excluded.utc,trip_cursor=excluded.trip_cursor
            """, [.real(odometer), .time(date)])
        return try calibration()
    }

    public func finishCalibration(odometer: Double, litres: Double, at date: Date = .now,
                                  attestsCoverage: Bool) throws -> FuelCalibrationState {
        let db = try database()
        guard active == nil, pendingEnd == nil else { throw FuelCalibrationError.activeEngine }
        guard attestsCoverage else { throw FuelCalibrationError.unobserved }
        let state = try calibration()
        guard let start = state.initialDate, let startKm = state.initialOdometer else { throw FuelCalibrationError.noStart }
        let officialKm = odometer - startKm
        guard officialKm.isFinite, officialKm > 0, odometer.isFinite, litres.isFinite, litres > 0,
              date > start else { throw FuelCalibrationError.invalid }

        let after = Int64(try db.scalar("SELECT trip_cursor FROM fill_start WHERE id=1") ?? 0)
        let through = Int64(try db.scalar("SELECT COALESCE(MAX(id),0) FROM trip") ?? 0)
        try db.transaction {
            try Self.commitCalibration(db, start: start, end: date, officialKm: officialKm, litres: litres,
                                       afterTrip: after, throughTrip: through)
            try db.run("UPDATE fill_start SET odometer=?,utc=?,trip_cursor=(SELECT MAX(id) FROM trip) WHERE id=1",
                       [.real(odometer), .time(date)])
        }
        return try calibration()
    }

    public func calibrateFromJournal(startID: UUID, endID: UUID, attestsCoverage: Bool) throws -> FuelCalibrationState {
        let db = try database()
        guard active == nil, pendingEnd == nil else { throw FuelCalibrationError.activeEngine }
        guard attestsCoverage else { throw FuelCalibrationError.unobserved }
        let ledger = try maintenanceWithoutAttachments()
        guard let interval = ledger.fuelIntervals.first(where: { $0.start.id == startID && $0.end.id == endID }),
              let start = interval.start.date.value, let end = interval.end.date.value, end > start else {
            throw FuelCalibrationError.invalid
        }
        // Start and finish dates are owner supplied. A trip crossing either point
        // makes the calibration interval ambiguous.
        let crossing = try db.scalar("""
            SELECT COUNT(*) FROM trip WHERE (started_utc<? AND last_utc>?)
              OR (started_utc<? AND last_utc>?)
            """, [.time(start), .time(start), .time(end), .time(end)]) ?? 0
        guard crossing == 0 else { throw FuelCalibrationError.unobserved }
        let first = try db.scalar("SELECT MIN(id) FROM trip WHERE started_utc>=? AND last_utc<=?",
                                  [.time(start), .time(end)])
        let last = try db.scalar("SELECT MAX(id) FROM trip WHERE started_utc>=? AND last_utc<=?",
                                 [.time(start), .time(end)])
        guard let first, let last, first >= 1, first <= last else { throw FuelCalibrationError.coverage }
        try db.transaction {
            try Self.commitCalibration(db, start: start, end: end, officialKm: interval.distanceKm, litres: interval.litres,
                                       afterTrip: Int64(first) - 1, throughTrip: Int64(last))
        }
        return try calibration()
    }

    private static func commitCalibration(_ db: DriveSQL, start: Date, end date: Date, officialKm: Double,
                                          litres: Double, afterTrip: Int64, throughTrip: Int64) throws {
        guard officialKm.isFinite, officialKm > 0, litres.isFinite, litres > 0, date > start else {
            throw FuelCalibrationError.invalid
        }
        let overlapping = try db.scalar("SELECT COUNT(*) FROM fill WHERE id>? AND start_utc<? AND end_utc>?",
                                        [.integer(try calibrationEpoch(db)), .time(date), .time(start)]) ?? 0
        guard overlapping == 0 else { throw FuelCalibrationError.alreadyCalibrated }
        let invalid = try db.scalar("""
            SELECT COUNT(*) FROM trip t WHERE t.id>? AND t.id<=?
              AND (t.finish IS NULL OR t.finish!='engine_stopped' OR t.engine_start_utc IS NULL
                OR t.engine_start_utc>t.started_utc+2 OR t.engine_start_utc<? OR t.started_utc<? OR t.last_utc>?
                OR EXISTS(SELECT 1 FROM gap g WHERE g.trip_id=t.id)
                OR EXISTS(SELECT 1 FROM event e WHERE e.trip_id=t.id AND kind='wall_clock_change'))
            """, [.integer(afterTrip), .integer(throughTrip), .time(start), .time(start), .time(date)]) ?? 0
        guard invalid == 0 else { throw FuelCalibrationError.unobserved }

        var coverage = (engine: 0.0, fuel: 0.0, km: 0.0, base: 0.0)
        try db.query("""
            SELECT SUM(x.observed)+SUM(x.before_record), SUM(x.fuel_seconds), SUM(x.paired_km), SUM(x.base)
            FROM (
              SELECT SUM(f.observed) AS observed, MAX(0,t.started_utc-t.engine_start_utc) AS before_record,
                SUM(CASE WHEN f.base_litres IS NOT NULL THEN f.observed ELSE 0 END) AS fuel_seconds,
                SUM(f.paired_km) AS paired_km,SUM(f.base_litres) AS base
              FROM trip t JOIN frame f ON f.trip_id=t.id
              WHERE t.id>? AND t.id<=? GROUP BY t.id
            ) x
            """, [.integer(afterTrip), .integer(throughTrip)]) { row in
            coverage = (sqlite3_column_double(row, 0), sqlite3_column_double(row, 1),
                        sqlite3_column_double(row, 2), sqlite3_column_double(row, 3))
        }
        guard coverage.base > 0, coverage.engine > 0, coverage.fuel / coverage.engine >= 0.90,
              (0.90...1.10).contains(coverage.km / officialKm), (litres / coverage.base).isFinite else {
            throw FuelCalibrationError.coverage
        }
        try db.run("INSERT INTO fill(start_utc,end_utc,km,litres,base_litres,engine_seconds,fuel_seconds,paired_km) VALUES(?,?,?,?,?,?,?,?)",
                   [.time(start), .time(date), .real(officialKm), .real(litres), .real(coverage.base),
                    .real(coverage.engine), .real(coverage.fuel), .real(coverage.km)])
    }

    private static func saveFrame(_ frame: TripFrame, id: Int64, elapsed: Double,
                           delta: TripInterval?, interrupted: Bool, database db: DriveSQL) throws {
        try db.run("""
            INSERT INTO frame(trip_id,utc,elapsed,rpm,speed,rate,calibration,observed,km,base_litres,litres,
                              paired_km,paired_litres,idle,idle_litres,discontinuous,fuel_method,fuel_valid_for)
                              VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.integer(id), .time(frame.timestamp), .real(elapsed), .optional(frame.rpm), .optional(frame.speed),
                  .optional(frame.fuel?.litresPerHour), .optional(frame.fuel?.calibration),
                  .real(delta?.observedSeconds ?? 0), .optional(delta?.distanceKm), .optional(delta?.baseLitres),
                  .optional(delta?.litres), .optional(delta?.pairedKm), .optional(delta?.pairedLitres),
                  .real(delta?.idleSeconds ?? 0), .optional(delta?.idleLitres), .integer(interrupted ? 1 : 0),
                  frame.fuel.map { _ in .text(FuelRate.method) } ?? .null,
                  .optional(frame.fuel?.validUntil.map { $0 - frame.monotonic })])
        let frameID = db.lastID
        for reading in frame.readings {
            try db.run("INSERT INTO reading(frame_id,signal,utc,offset,value,quality,bytes) VALUES(?,?,?,?,?,?,?)",
                       [.integer(frameID), .integer(Int64(reading.signal.rawValue)), .time(reading.timestamp),
                        .real(reading.monotonic - frame.monotonic), .optional(reading.value),
                        .text(reading.quality.rawValue), .text(reading.bytes.map { String(format: "%02X", $0) }.joined())])
        }
    }

    static let schemaV1 = """
        CREATE TABLE trip(id INTEGER PRIMARY KEY,owner TEXT NOT NULL,started_utc REAL NOT NULL,
          last_utc REAL NOT NULL,engine_start_utc REAL,connected_utc REAL,finish TEXT);
        CREATE TABLE frame(id INTEGER PRIMARY KEY,trip_id INTEGER NOT NULL REFERENCES trip(id),
          utc REAL NOT NULL,elapsed REAL NOT NULL,rpm REAL,speed REAL,rate REAL,calibration REAL,observed REAL NOT NULL,
          km REAL,base_litres REAL,litres REAL,paired_km REAL,paired_litres REAL,idle REAL NOT NULL,idle_litres REAL,
          discontinuous INTEGER NOT NULL,fuel_method TEXT,fuel_valid_for REAL,UNIQUE(trip_id,elapsed));
        CREATE TABLE reading(frame_id INTEGER NOT NULL REFERENCES frame(id),signal INTEGER NOT NULL,utc REAL NOT NULL,
          offset REAL NOT NULL,value REAL,quality TEXT NOT NULL,bytes TEXT NOT NULL,PRIMARY KEY(frame_id,signal)) WITHOUT ROWID;
        CREATE TABLE gap(id INTEGER PRIMARY KEY,trip_id INTEGER NOT NULL REFERENCES trip(id),started_utc REAL NOT NULL,
          resumed_utc REAL,reason TEXT NOT NULL);
        CREATE INDEX gap_by_trip ON gap(trip_id);
        CREATE TABLE event(id INTEGER PRIMARY KEY,trip_id INTEGER REFERENCES trip(id),utc REAL NOT NULL,
          kind TEXT NOT NULL,payload TEXT NOT NULL);
        CREATE INDEX event_by_trip ON event(trip_id,kind);
        CREATE TABLE fill(id INTEGER PRIMARY KEY,start_utc REAL NOT NULL,end_utc REAL NOT NULL,km REAL NOT NULL,
          litres REAL NOT NULL,base_litres REAL NOT NULL,engine_seconds REAL NOT NULL,
          fuel_seconds REAL NOT NULL,paired_km REAL NOT NULL);
        CREATE TABLE fill_start(id INTEGER PRIMARY KEY CHECK(id=1),odometer REAL NOT NULL,utc REAL NOT NULL,
          trip_cursor INTEGER NOT NULL);
        PRAGMA user_version=1;
        """
}
