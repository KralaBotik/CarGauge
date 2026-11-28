import Foundation

public struct FuelRate: Codable, Equatable, Sendable {
    public static let method = "g4fc-speed-density-closed-loop-v1"
    public let litresPerHour: Double
    public let baseLitresPerHour: Double
    public let calibration: Double
    public let validUntil: Double?

    init(litresPerHour: Double, baseLitresPerHour: Double, calibration: Double, validUntil: Double? = nil) {
        self.litresPerHour = litresPerHour
        self.baseLitresPerHour = baseLitresPerHour
        self.calibration = calibration
        self.validUntil = validUntil
    }

    public func litresPer100km(speed: Double?) -> Double? {
        guard let speed, speed.isFinite, speed > 0 else { return nil }
        return litresPerHour * 100 / speed
    }
}

public enum SpeedDensity {
    // References from Kılıç & Önler, Applied Sciences 16 (2026), §§2.4–2.5.
    // These are modelling assumptions. VE is not a Hyundai calibration.
    public static let displacementM3 = 0.001591
    public static let referenceVE = 0.85
    public static let referenceAFR = 14.7
    public static let fuelDensityKGPerLitre = 0.740
    public static let dryAirGasConstant = 287.05

    public static func estimate(readings: [DriveSignal: DriveReading], at now: Double,
                                targetProfile: Bool, calibration: Double = 1) -> FuelRate? {
        guard targetProfile, calibration.isFinite, calibration > 0,
              let rpm = fresh(.rpm, in: readings, at: now, age: 3), rpm > 0,
              let map = fresh(.map, in: readings, at: now, age: 3), map > 0,
              let intake = fresh(.intake, in: readings, at: now, age: 25),
              let status = readings[.fuelStatus], status.isFresh(at: now, within: 5), status.bytes == [2, 0] else {
            return nil
        }
        if let lambda = fresh(.commandedLambda, in: readings, at: now, age: 12),
           !(0.97...1.03).contains(lambda) { return nil }
        let kelvin = intake + 273.15
        guard kelvin > 0 else { return nil }
        let airKGPerSecond = map * 1000 / (dryAirGasConstant * kelvin)
            * displacementM3 * rpm * referenceVE / 120
        let base = airKGPerSecond * 3600 / (referenceAFR * fuelDensityKGPerLitre)
        let corrected = base * calibration
        guard corrected.isFinite, base > 0 else { return nil }
        let limits: [(DriveSignal, Double)] = [(.rpm, 3), (.map, 3), (.fuelStatus, 5), (.intake, 25)]
        let expires = limits.compactMap { signal, age in readings[signal].map { $0.monotonic + age } }.min()
        return FuelRate(litresPerHour: corrected, baseLitresPerHour: base, calibration: calibration, validUntil: expires)
    }

    private static func fresh(_ signal: DriveSignal, in readings: [DriveSignal: DriveReading],
                              at now: Double, age: Double) -> Double? {
        guard let reading = readings[signal], reading.isFresh(at: now, within: age),
              let value = reading.value, value.isFinite else { return nil }
        return value
    }
}

/// Two coherent running-engine observations are required for a bounded estimate of start.
public struct EngineStartEvidence: Sendable {
    private var first: DriveReading?
    public init() {}

    public mutating func observe(_ reading: DriveReading?, rpm: DriveReading?) -> Date? {
        guard let reading, reading.signal == .runTime, reading.quality == .received,
              let value = reading.value, (1..<65535).contains(value),
              let rpm, rpm.isFresh(at: max(rpm.monotonic, reading.monotonic), within: 4),
              abs(rpm.monotonic - reading.monotonic) <= 4, let speed = rpm.value, speed > 0 else {
            first = nil
            return nil
        }
        guard let preceding = first, let old = preceding.value else {
            first = reading
            return nil
        }
        let elapsed = reading.monotonic - preceding.monotonic
        guard elapsed > 0 else { return nil }
        first = reading
        guard elapsed <= 30, value > old, abs((value - old) - elapsed) <= 2,
              abs(reading.timestamp.timeIntervalSince(preceding.timestamp) - elapsed) <= 2 else { return nil }
        return preceding.timestamp.addingTimeInterval(-old)
    }
}
