import Foundation

public enum DataSource: String, Codable, Sendable { case simulator, vehicle }
public enum VoltageSource: String, Codable, Sendable { case ecu, adapter }
public enum ThermalLevel: String, Codable, Sendable { case normal, warning, critical }
public enum EngineTemperatureState: Sendable { case warmingUp, operating, warning, critical }

/// User-selected display and alert thresholds in degrees Celsius.
public struct ThermalThresholds: Codable, Equatable, Sendable {
    public enum Limit: CaseIterable, Sendable { case operating, warning, critical }

    public let operating: Int
    public let warning: Int
    public let critical: Int

    public static let standard = ThermalThresholds(operating: 80, warning: 105, critical: 115)!
    private static let separation = 4

    public init?(operating: Int, warning: Int, critical: Int) {
        guard (40...120).contains(operating), (64...136).contains(warning), (68...140).contains(critical),
              warning - operating >= Self.separation, critical - warning >= Self.separation else { return nil }
        self.operating = operating
        self.warning = warning
        self.critical = critical
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let operating = try values.decode(Int.self, forKey: .operating)
        let warning = try values.decode(Int.self, forKey: .warning)
        let critical = try values.decode(Int.self, forKey: .critical)
        guard let thresholds = Self(operating: operating, warning: warning, critical: critical) else {
            throw DecodingError.dataCorruptedError(forKey: .warning, in: values, debugDescription: "Invalid temperature thresholds")
        }
        self = thresholds
    }

    public subscript(limit: Limit) -> Int {
        switch limit {
        case .operating: operating
        case .warning: warning
        case .critical: critical
        }
    }

    public func range(for limit: Limit) -> ClosedRange<Int> {
        switch limit {
        case .operating: 40...min(120, warning - Self.separation)
        case .warning: max(64, operating + Self.separation)...min(136, critical - Self.separation)
        case .critical: max(68, warning + Self.separation)...140
        }
    }

    public func setting(_ limit: Limit, to value: Int) -> Self? {
        Self(operating: limit == .operating ? value : operating,
             warning: limit == .warning ? value : warning,
             critical: limit == .critical ? value : critical)
    }

    public func state(at temperature: Double, alert: ThermalLevel) -> EngineTemperatureState {
        if alert == .critical || temperature >= Double(critical) { return .critical }
        if alert == .warning || temperature >= Double(warning) { return .warning }
        return temperature < Double(operating) ? .warmingUp : .operating
    }
}

public struct Reading: Codable, Equatable, Sendable {
    public var value: Double
    public var timestamp: Date

    public init(_ value: Double, at timestamp: Date) {
        self.value = value
        self.timestamp = timestamp
    }

    public func isFresh(at now: Date, maxAge: TimeInterval = 5) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return value.isFinite && age >= -1 && age < maxAge
    }
}

public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    public var source: DataSource
    public var coolant: Reading
    public var rpm: Reading?
    public var voltage: Reading?
    public var voltageSource: VoltageSource

    public init(source: DataSource, coolant: Reading, rpm: Reading?, voltage: Reading?, voltageSource: VoltageSource) {
        self.source = source
        self.coolant = coolant
        self.rpm = rpm
        self.voltage = voltage
        self.voltageSource = voltageSource
    }
}

/// Prototype thresholds, NOT Hyundai service specifications.
public struct OverheatMonitor: Sendable {
    public private(set) var level: ThermalLevel = .normal
    public private(set) var warning: Double
    public private(set) var critical: Double
    public let hysteresis: Double

    public init(warning: Double = 105, critical: Double = 115, hysteresis: Double = 3) {
        precondition(warning.isFinite && critical.isFinite && hysteresis.isFinite)
        precondition(warning < critical && hysteresis > 0)
        self.warning = warning
        self.critical = critical
        self.hysteresis = hysteresis
    }

    public mutating func apply(_ thresholds: ThermalThresholds) {
        warning = Double(thresholds.warning)
        critical = Double(thresholds.critical)
    }

    /// Missing/stale data must not clear a previously observed warning.
    @discardableResult public mutating func update(_ reading: Reading?, at now: Date) -> ThermalLevel {
        guard let reading, reading.isFresh(at: now) else { return level }
        let temperature = reading.value
        if temperature >= critical { level = .critical }
        else if level == .critical && temperature > critical - hysteresis { level = .critical }
        else if temperature >= warning { level = .warning }
        else if level != .normal && temperature > warning - hysteresis { level = .warning }
        else { level = .normal }
        return level
    }
}

public struct WarmupHistory: Sendable {
    public struct Point: Identifiable, Sendable {
        public let reading: Reading
        public let segment: Int
        public var id: Date { reading.timestamp }
    }

    public private(set) var points: [Point] = []
    public var readings: [Reading] { points.map(\.reading) }
    public let capacity: Int
    public let duration: TimeInterval
    private var segment = 0
    private var interrupted = false

    public init(capacity: Int = 1800, duration: TimeInterval = 1800) {
        precondition(capacity > 0 && duration > 0)
        self.capacity = capacity
        self.duration = duration
    }

    public mutating func interrupt() { interrupted = true }

    public mutating func append(_ reading: Reading) {
        guard reading.value.isFinite else { return }
        if let last = points.last {
            let elapsed = reading.timestamp.timeIntervalSince(last.reading.timestamp)
            guard elapsed > 0 else { return }
            if interrupted || elapsed >= 5 { segment += 1 }
        }
        interrupted = false
        points.append(Point(reading: reading, segment: segment))
        let expired = points.prefix { reading.timestamp.timeIntervalSince($0.reading.timestamp) > duration }.count
        let excess = points.count - capacity
        points.removeFirst(max(expired, excess))
    }
}

public struct ReconnectBackoff: Sendable {
    private var attempt = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval {
        defer { attempt = min(attempt + 1, 5) }
        return min(pow(2, Double(attempt)), 30)
    }
    public mutating func reset() { attempt = 0 }
}
