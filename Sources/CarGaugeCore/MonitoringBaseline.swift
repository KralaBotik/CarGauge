import Foundation

struct MonitoringBucket: Codable, Hashable, Sendable {
    let regime: MonitoringRegime
    let ambientBand: Int
    let loadBand: Int
    let speedBand: Int
}

struct MonitoringBaselineKey: Codable, Hashable, Sendable {
    let signal: DriveSignal
    let bucket: MonitoringBucket
}

public struct MonitoringBaselineInfo: Identifiable, Codable, Sendable {
    public var id: String { "\(signal.command)-\(regime.rawValue)-\(ambientBand)-\(loadBand)-\(speedBand)" }
    public let version: Int
    public let signal: DriveSignal
    public let regime: MonitoringRegime
    public let ambientBand: Int
    public let loadBand: Int
    public let speedBand: Int
    public let sampleCount: Int
    public let tripCount: Int
    public let median: Double?
    public let medianAbsoluteDeviation: Double?
    public var isSufficient: Bool { median != nil && medianAbsoluteDeviation != nil }
}

struct MonitoringBaseline: Codable, Sendable {
    struct Sample: Codable, Sendable {
        let trip: Int64
        let value: Double
    }

    static let version = 1
    static let signals: Set<DriveSignal> = [.coolant, .rpm, .shortTrim, .longTrim, .map, .adapterVoltage,
                                            .ecuVoltage, .oxygen1, .oxygen2, .catalyst]

    private var buckets: [MonitoringBaselineKey: [Sample]] = [:]

    func info(_ key: MonitoringBaselineKey) -> MonitoringBaselineInfo {
        let samples = buckets[key, default: []]
        let tripCount = Set(samples.map(\.trip)).count
        let ready = tripCount >= 5 && samples.count >= 30
        let center = ready ? Self.median(samples.map(\.value)) : nil
        let mad = center.flatMap { middle in Self.median(samples.map { abs($0.value - middle) }) }
        return MonitoringBaselineInfo(version: Self.version, signal: key.signal, regime: key.bucket.regime,
                                      ambientBand: key.bucket.ambientBand, loadBand: key.bucket.loadBand,
                                      speedBand: key.bucket.speedBand, sampleCount: samples.count, tripCount: tripCount,
                                      median: center, medianAbsoluteDeviation: mad)
    }

    mutating func learn(key: MonitoringBaselineKey, trip: Int64, value: Double) {
        guard value.isFinite else { return }
        let current = buckets[key, default: []]
        guard current.count(where: { $0.trip == trip }) < 12 else { return }
        let baseline = info(key)
        if let center = baseline.median, let mad = baseline.medianAbsoluteDeviation {
            let floor = Self.quantizationFloor(for: key.signal)
            guard abs(value - center) <= max(6 * mad, floor) else { return }
        }

        // Histories remain bounded after long on-device use. Old buckets remain in the exported archive
        // as snapshots from their monitored trips when the app chooses to persist them.
        guard buckets.count < 256 || buckets[key] != nil else { return }
        var next = current
        next.append(Sample(trip: trip, value: value))
        if next.count > 120 { next.removeFirst(next.count - 120) }
        buckets[key] = next
    }

    mutating func discard(trip: Int64) {
        for key in Array(buckets.keys) {
            buckets[key]?.removeAll { $0.trip == trip }
            if buckets[key]?.isEmpty == true { buckets[key] = nil }
        }
    }

    var storedInfo: [MonitoringBaselineInfo] {
        buckets.keys.map(info).sorted { $0.id < $1.id }
    }

    func allInfo(in bucket: MonitoringBucket?) -> [MonitoringBaselineInfo] {
        guard let bucket else { return [] }
        return Self.signals.sorted { $0.rawValue < $1.rawValue }.map { info(.init(signal: $0, bucket: bucket)) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func quantizationFloor(for signal: DriveSignal) -> Double {
        switch signal {
        case .rpm: 50
        case .coolant, .map, .shortTrim, .longTrim: 4
        case .adapterVoltage, .ecuVoltage: 0.25
        case .oxygen1, .oxygen2: 0.1
        case .catalyst: 30
        default: 1
        }
    }
}

/// The result is comparative context. It cannot drive a diagnostic alert.
public struct MonitoringTripFuelObservation: Codable, Sendable {
    public let tripID: Int64
    public let averageLitresPer100km: Double
    public let coverage: Double
    public let estimatedDistanceKM: Double
    public let averageSpeedKPH: Double
    public let averageLoadPercent: Double
    public let averageAmbientCelsius: Double
    public let coveredRegime: MonitoringRegime
    public let modelKey: String

    public init(tripID: Int64, averageLitresPer100km: Double, coverage: Double, estimatedDistanceKM: Double,
                averageSpeedKPH: Double, averageLoadPercent: Double, averageAmbientCelsius: Double,
                coveredRegime: MonitoringRegime, modelKey: String) {
        self.tripID = tripID
        self.averageLitresPer100km = averageLitresPer100km
        self.coverage = coverage
        self.estimatedDistanceKM = estimatedDistanceKM
        self.averageSpeedKPH = averageSpeedKPH
        self.averageLoadPercent = averageLoadPercent
        self.averageAmbientCelsius = averageAmbientCelsius
        self.coveredRegime = coveredRegime
        self.modelKey = modelKey
    }

    var eligible: Bool {
        [averageLitresPer100km, coverage, estimatedDistanceKM, averageSpeedKPH, averageLoadPercent, averageAmbientCelsius]
            .allSatisfy(\.isFinite) && (0.8...1).contains(coverage) && averageLitresPer100km > 0 && estimatedDistanceKM > 0
            && averageSpeedKPH > 0 && (0...100).contains(averageLoadPercent) && !modelKey.isEmpty
            && [.moving, .higherLoad].contains(coveredRegime)
    }
}

public struct MonitoringFuelTrend: Codable, Sendable {
    public let version: Int
    public let medianLitresPer100km: Double
    public let differenceLitresPer100km: Double
    public let referenceTripCount: Int

    public static func compare(_ current: MonitoringTripFuelObservation,
                               references: [MonitoringTripFuelObservation]) -> Self? {
        guard current.eligible else { return nil }
        var observedTrips: Set<Int64> = []
        let comparable = references.filter {
            $0.eligible && $0.tripID != current.tripID && $0.modelKey == current.modelKey
                && $0.coveredRegime == current.coveredRegime && abs($0.averageSpeedKPH - current.averageSpeedKPH) <= 10
                && abs($0.averageLoadPercent - current.averageLoadPercent) <= 10
                && abs($0.averageAmbientCelsius - current.averageAmbientCelsius) <= 5
                && (0.7...1.3).contains($0.estimatedDistanceKM / current.estimatedDistanceKM)
                && observedTrips.insert($0.tripID).inserted
        }
        guard comparable.count >= 5,
              let median = MonitoringBaseline.median(comparable.map(\.averageLitresPer100km)) else { return nil }
        return Self(version: 1, medianLitresPer100km: median,
                    differenceLitresPer100km: current.averageLitresPer100km - median,
                    referenceTripCount: comparable.count)
    }
}
