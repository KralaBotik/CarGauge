import Foundation

public struct TripFrame: Sendable {
    public let timestamp: Date
    public let monotonic: Double
    public let readings: [DriveReading]
    public let rpm: Double?
    public let speed: Double?
    public let fuel: FuelRate?
    public let estimatedEngineStart: Date?
    public let connectedAt: Date?

    public init(timestamp: Date, monotonic: Double, readings: [DriveReading], rpm: Double?, speed: Double?,
                fuel: FuelRate?, estimatedEngineStart: Date? = nil, connectedAt: Date? = nil) {
        self.timestamp = timestamp
        self.monotonic = monotonic
        self.readings = readings
        self.rpm = rpm
        self.speed = speed
        self.fuel = fuel
        self.estimatedEngineStart = estimatedEngineStart
        self.connectedAt = connectedAt
    }
}

public struct TripInterval: Equatable, Sendable {
    public static let maximumGap: Double = 6
    public var observedSeconds: Double = 0
    public var distanceKm: Double?
    public var baseLitres: Double?
    public var litres: Double?
    public var pairedKm: Double?
    public var pairedLitres: Double?
    public var idleSeconds: Double = 0
    public var idleLitres: Double?

    public static func between(_ a: TripFrame, _ b: TripFrame) -> Self? {
        let elapsed = b.monotonic - a.monotonic
        guard elapsed > 0, elapsed <= maximumGap else { return nil }
        var interval = Self()
        // An observed stop or absent RPM ends the common engine-running coverage.
        guard let rpmA = a.rpm, let rpmB = b.rpm, rpmA > 0, rpmB > 0 else { return interval }
        interval.observedSeconds = elapsed
        if let x = a.speed, let y = b.speed, x >= 0, y >= 0, x.isFinite, y.isFinite {
            interval.distanceKm = (x + y) * elapsed / 7200
            if x == 0, y == 0 { interval.idleSeconds = elapsed }
        }
        if let x = a.fuel, let y = b.fuel, x.calibration == y.calibration,
           x.validUntil.map({ $0 >= b.monotonic }) ?? true {
            interval.baseLitres = (x.baseLitresPerHour + y.baseLitresPerHour) * elapsed / 7200
            interval.litres = (x.litresPerHour + y.litresPerHour) * elapsed / 7200
        }
        if let distance = interval.distanceKm, let fuel = interval.litres {
            interval.pairedKm = distance
            interval.pairedLitres = fuel
            if interval.idleSeconds > 0 { interval.idleLitres = fuel }
        }
        return interval
    }
}

public struct RecordedTrip: Identifiable, Sendable {
    public let id: Int64
    public let startedAt: Date
    public let lastObservation: Date
    public let finishReason: String?
    public let elapsedSeconds: Double
    public let estimatedEngineStart: Date?
    public let connectedAt: Date?
    public let observedEngineSeconds: Double
    public let distanceKm: Double?
    public let distanceSeconds: Double
    public let litres: Double?
    public let fuelSeconds: Double
    public let averageLitresPer100km: Double?
    public let idleSeconds: Double
    public let idleLitres: Double?
    public let peakSpeed: Double?
}

public struct TripPlot: Sendable {
    public struct Point: Identifiable, Sendable {
        public let id: Int64
        public let time: Double
        public let value: Double
        public let segment: Int
    }
    public let seconds: Double
    public let series: [DriveSignal: [Point]]
    public let fuel: [Point]
    public let gaps: Int
}

public struct FuelCalibrationState: Sendable {
    public let factor: Double
    public let initialOdometer: Double?
    public let initialDate: Date?
    public let matchedFills: Int
}

public enum FuelCalibrationError: LocalizedError {
    case invalid, coverage, alreadyStarted, noStart, activeEngine, unobserved
    public var errorDescription: String? {
        switch self {
        case .invalid: "Проверьте литры и показания одометра полной заправки."
        case .coverage: "Мало данных между заправками. Нужно покрыть не менее 90% пробега и 90% наблюдаемой работы двигателя."
        case .alreadyStarted: "Начальная заправка уже записана."
        case .noStart: "Сначала отметьте полную заправку."
        case .activeEngine: "Завершите текущую запись с остановленным двигателем."
        case .unobserved: "В интервале есть поездки с неизвестной границей работы двигателя."
        }
    }
}
