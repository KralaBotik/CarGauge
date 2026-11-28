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
    }

    private let url: URL
    private var connection: DriveSQL?
    private var active: Active?
    // Reject older session tasks that resume after stop or replacement.
    private var endedOwners: [UUID] = []

    public init(url: URL) { self.url = url }

    private func database() throws -> DriveSQL {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try DriveSQL(url: url)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        let version = try db.scalar("PRAGMA user_version") ?? 0
        guard version == 0 || version == 1 else { throw DriveSQL.Failure(message: "Неподдерживаемая версия локальной истории.") }
        try db.transaction {
            if version == 0 { try db.execute(Self.schema) }
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

    public func record(owner: UUID, frame: TripFrame) throws {
        guard !endedOwners.contains(owner), frame.monotonic.isFinite else { return }
        let db = try database()
        if let active {
            guard active.owner == owner, frame.monotonic > active.previous.monotonic else { return }
            let delta = TripInterval.between(active.previous, frame)
            let stopped = frame.rpm == 0
            try db.transaction {
                try Self.saveFrame(frame, id: active.id, elapsed: frame.monotonic - active.origin, delta: delta, database: db)
                if delta == nil || delta?.observedSeconds == 0 && !stopped {
                    try db.run("INSERT INTO gap(trip_id,started_utc,resumed_utc,reason) VALUES (?,?,?,?)",
                               [.integer(active.id), .time(active.previous.timestamp), .time(frame.timestamp), .text("coverage")])
                }
                try db.run("""
                    UPDATE trip SET last_utc=?, engine_start_utc=COALESCE(engine_start_utc,?),
                        finish=CASE WHEN ? THEN 'engine_stopped' ELSE finish END WHERE id=?
                    """, [.time(frame.timestamp), .time(frame.estimatedEngineStart), .integer(stopped ? 1 : 0), .integer(active.id)])
            }
            self.active = stopped ? nil : Active(owner: owner, id: active.id, origin: active.origin, previous: frame)
        } else if let rpm = frame.rpm, rpm > 0 {
            let id = try db.transaction {
                try db.run("INSERT INTO trip(owner,started_utc,last_utc,engine_start_utc) VALUES (?,?,?,?)",
                           [.text(owner.uuidString), .time(frame.timestamp), .time(frame.timestamp), .time(frame.estimatedEngineStart)])
                let id = db.lastID
                try Self.saveFrame(frame, id: id, elapsed: 0, delta: nil, database: db)
                try db.run("UPDATE gap SET resumed_utc=? WHERE resumed_utc IS NULL AND trip_id != ?",
                           [.time(frame.timestamp), .integer(id)])
                return id
            }
            active = Active(owner: owner, id: id, origin: frame.monotonic, previous: frame)
        }
    }

    public func end(owner: UUID, reason: String, mayResume: Bool = false) throws {
        if !mayResume && !endedOwners.contains(owner) {
            endedOwners.append(owner)
            if endedOwners.count > 64 { endedOwners.removeFirst() }
        }
        guard let active, active.owner == owner else { return }
        let db = try database()
        try db.transaction {
            try db.run("UPDATE trip SET finish=? WHERE id=?", [.text(reason), .integer(active.id)])
            if reason != "engine_stopped" {
                try db.run("INSERT INTO gap(trip_id,started_utc,reason) VALUES (?,?,?)",
                           [.integer(active.id), .time(active.previous.timestamp), .text(reason)])
            }
        }
        self.active = nil
    }

    public func addEvent(kind: String, payload: String, timestamp: Date = .now) throws {
        try database().run("INSERT INTO event(trip_id,utc,kind,payload) VALUES (?,?,?,?)",
                           [active.map { .integer($0.id) } ?? .null, .time(timestamp), .text(kind), .text(payload)])
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

    private func trips(condition: String, bindings: [DriveSQL.Value]) throws -> [RecordedTrip] {
        let db = try database()
        var trips: [RecordedTrip] = []
        try db.query("""
            SELECT t.id,t.started_utc,t.last_utc,t.finish,t.engine_start_utc,MAX(f.elapsed),
              SUM(f.observed),SUM(f.km),SUM(CASE WHEN f.km IS NOT NULL THEN f.observed ELSE 0 END),
              SUM(f.litres),SUM(CASE WHEN f.litres IS NOT NULL THEN f.observed ELSE 0 END),
              100*SUM(f.paired_litres)/NULLIF(SUM(f.paired_km),0),SUM(f.idle),SUM(f.idle_litres),MAX(f.speed)
            FROM (SELECT * FROM trip t WHERE \(condition) ORDER BY id DESC LIMIT ?) t
              JOIN frame f ON f.trip_id=t.id GROUP BY t.id ORDER BY t.id DESC
            """, bindings) { row in
            trips.append(RecordedTrip(id: sqlite3_column_int64(row, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                lastObservation: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                finishReason: DriveSQL.string(row, 3), elapsedSeconds: sqlite3_column_double(row, 5),
                estimatedEngineStart: DriveSQL.number(row, 4).map(Date.init(timeIntervalSince1970:)),
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
        var last: [DriveSignal: (Double, Int)] = [:]
        var fuelSegment = 0
        var lastFuel: Double?
        var openFrame: Int64?
        return try db.transaction(readOnly: true) {
            try db.query("""
                SELECT f.id,f.elapsed,f.rate,r.signal,r.value,r.quality FROM frame f
                  LEFT JOIN reading r ON r.frame_id=f.id WHERE f.trip_id=? ORDER BY f.elapsed,f.id
                """, [.integer(tripID)]) { row in
                let id = sqlite3_column_int64(row, 0)
                let time = sqlite3_column_double(row, 1)
                elapsed = max(elapsed, time)
                if openFrame != id {
                    openFrame = id
                    if let rate = DriveSQL.number(row, 2) {
                        if lastFuel.map({ time - $0 > TripInterval.maximumGap }) ?? true { fuelSegment += 1 }
                        fuel.append(.init(id: id, time: time, value: rate, segment: fuelSegment))
                        lastFuel = time
                    } else {
                        lastFuel = nil
                    }
                }
                guard let signal = DriveSignal(rawValue: UInt8(clamping: sqlite3_column_int(row, 3))),
                      channels.contains(signal) else { return }
                let previous = last[signal]
                let horizon = max(TripInterval.maximumGap, signal.cadence * 2.5)
                let segment = (previous?.1 ?? 0) + ((previous.map { time - $0.0 <= horizon } ?? false) ? 0 : 1)
                guard DriveSQL.string(row, 5) == DriveReading.Quality.received.rawValue,
                      let value = DriveSQL.number(row, 4) else {
                    last[signal] = (-Double.infinity, segment)
                    return
                }
                last[signal] = (time, segment)
                series[signal, default: []].append(.init(id: id, time: time, value: value, segment: segment))
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
        let factor = try db.scalar("SELECT SUM(litres)/NULLIF(SUM(base_litres),0) FROM fill") ?? 1
        let count = try db.scalar("SELECT COUNT(*) FROM fill") ?? 0
        var start: (Double, Date)?
        try db.query("SELECT odometer,utc FROM fill_start WHERE id=1") { row in
            start = (sqlite3_column_double(row, 0), Date(timeIntervalSince1970: sqlite3_column_double(row, 1)))
        }
        return FuelCalibrationState(factor: factor, initialOdometer: start?.0, initialDate: start?.1, matchedFills: Int(count))
    }

    public func startCalibration(odometer: Double, at date: Date = .now) throws -> FuelCalibrationState {
        guard odometer.isFinite, odometer >= 0 else { throw FuelCalibrationError.invalid }
        let db = try database()
        guard try calibration().initialOdometer == nil else { throw FuelCalibrationError.alreadyStarted }
        try db.run("INSERT INTO fill_start(id,odometer,utc) VALUES(1,?,?)", [.real(odometer), .time(date)])
        return try calibration()
    }

    public func restartCalibration(odometer: Double, at date: Date = .now) throws -> FuelCalibrationState {
        guard odometer.isFinite, odometer >= 0 else { throw FuelCalibrationError.invalid }
        try database().run("""
            INSERT INTO fill_start(id,odometer,utc) VALUES(1,?,?)
            ON CONFLICT(id) DO UPDATE SET odometer=excluded.odometer, utc=excluded.utc
            """, [.real(odometer), .time(date)])
        return try calibration()
    }

    public func finishCalibration(odometer: Double, litres: Double, at date: Date = .now) throws -> FuelCalibrationState {
        let db = try database()
        let state = try calibration()
        guard let start = state.initialDate, let startKm = state.initialOdometer else { throw FuelCalibrationError.noStart }
        let officialKm = odometer - startKm
        guard officialKm.isFinite, officialKm > 0, odometer.isFinite, litres.isFinite, litres > 0,
              date > start else { throw FuelCalibrationError.invalid }
        var coverage = (engine: 0.0, fuel: 0.0, km: 0.0, base: 0.0)
        try db.query("""
            SELECT SUM(f.observed),SUM(CASE WHEN f.base_litres IS NOT NULL THEN f.observed ELSE 0 END),
              SUM(f.km),SUM(f.base_litres)
            FROM trip t JOIN frame f ON f.trip_id=t.id
            WHERE t.started_utc>=? AND t.last_utc<=? AND t.finish='engine_stopped'
            """, [.time(start), .time(date)]) { row in
            coverage = (sqlite3_column_double(row, 0), sqlite3_column_double(row, 1),
                        sqlite3_column_double(row, 2), sqlite3_column_double(row, 3))
        }
        guard coverage.base > 0, coverage.engine > 0, coverage.fuel / coverage.engine >= 0.90,
              (0.90...1.10).contains(coverage.km / officialKm) else { throw FuelCalibrationError.coverage }
        try db.transaction {
            try db.run("INSERT INTO fill(start_utc,end_utc,km,litres,base_litres) VALUES(?,?,?,?,?)",
                       [.time(start), .time(date), .real(officialKm), .real(litres), .real(coverage.base)])
            try db.run("UPDATE fill_start SET odometer=?,utc=? WHERE id=1", [.real(odometer), .time(date)])
        }
        return try calibration()
    }

    private static func saveFrame(_ frame: TripFrame, id: Int64, elapsed: Double,
                           delta: TripInterval?, database db: DriveSQL) throws {
        try db.run("""
            INSERT INTO frame(trip_id,utc,elapsed,rpm,speed,rate,calibration,observed,km,base_litres,litres,
                              paired_km,paired_litres,idle,idle_litres) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.integer(id), .time(frame.timestamp), .real(elapsed), .optional(frame.rpm), .optional(frame.speed),
                  .optional(frame.fuel?.litresPerHour), .optional(frame.fuel?.calibration),
                  .real(delta?.observedSeconds ?? 0), .optional(delta?.distanceKm), .optional(delta?.baseLitres),
                  .optional(delta?.litres), .optional(delta?.pairedKm), .optional(delta?.pairedLitres),
                  .real(delta?.idleSeconds ?? 0), .optional(delta?.idleLitres)])
        let frameID = db.lastID
        for reading in frame.readings {
            try db.run("INSERT INTO reading(frame_id,signal,utc,offset,value,quality,bytes) VALUES(?,?,?,?,?,?,?)",
                       [.integer(frameID), .integer(Int64(reading.signal.rawValue)), .time(reading.timestamp),
                        .real(reading.monotonic - frame.monotonic), .optional(reading.value),
                        .text(reading.quality.rawValue), .text(reading.bytes.map { String(format: "%02X", $0) }.joined())])
        }
    }

    private static let schema = """
        CREATE TABLE trip(id INTEGER PRIMARY KEY,owner TEXT NOT NULL,started_utc REAL NOT NULL,
          last_utc REAL NOT NULL,engine_start_utc REAL,finish TEXT);
        CREATE TABLE frame(id INTEGER PRIMARY KEY,trip_id INTEGER NOT NULL REFERENCES trip(id),
          utc REAL NOT NULL,elapsed REAL NOT NULL,rpm REAL,speed REAL,rate REAL,calibration REAL,observed REAL NOT NULL,
          km REAL,base_litres REAL,litres REAL,paired_km REAL,paired_litres REAL,idle REAL NOT NULL,idle_litres REAL,
          UNIQUE(trip_id,elapsed));
        CREATE TABLE reading(frame_id INTEGER NOT NULL REFERENCES frame(id),signal INTEGER NOT NULL,utc REAL NOT NULL,
          offset REAL NOT NULL,value REAL,quality TEXT NOT NULL,bytes TEXT NOT NULL,PRIMARY KEY(frame_id,signal)) WITHOUT ROWID;
        CREATE TABLE gap(id INTEGER PRIMARY KEY,trip_id INTEGER NOT NULL REFERENCES trip(id),started_utc REAL NOT NULL,
          resumed_utc REAL,reason TEXT NOT NULL);
        CREATE INDEX gap_by_trip ON gap(trip_id);
        CREATE TABLE event(id INTEGER PRIMARY KEY,trip_id INTEGER REFERENCES trip(id),utc REAL NOT NULL,
          kind TEXT NOT NULL,payload TEXT NOT NULL);
        CREATE TABLE fill(id INTEGER PRIMARY KEY,start_utc REAL NOT NULL,end_utc REAL NOT NULL,km REAL NOT NULL,
          litres REAL NOT NULL,base_litres REAL NOT NULL);
        CREATE TABLE fill_start(id INTEGER PRIMARY KEY CHECK(id=1),odometer REAL NOT NULL,utc REAL NOT NULL);
        PRAGMA user_version=1;
        """
}
