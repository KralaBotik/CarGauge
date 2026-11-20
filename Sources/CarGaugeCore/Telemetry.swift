import Foundation

public enum DataSource: String, Codable, Sendable { case simulator, vehicle }
public enum VoltageSource: String, Codable, Sendable { case ecu, adapter }
public enum ThermalLevel: String, Codable, Sendable { case normal, warning, critical }

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
    public let warning: Double
    public let critical: Double
    public let hysteresis: Double

    public init(warning: Double = 105, critical: Double = 115, hysteresis: Double = 3) {
        precondition(warning.isFinite && critical.isFinite && hysteresis.isFinite)
        precondition(warning < critical && hysteresis > 0)
        self.warning = warning
        self.critical = critical
        self.hysteresis = hysteresis
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
    public private(set) var readings: [Reading] = []
    public let capacity: Int
    public let duration: TimeInterval

    public init(capacity: Int = 1800, duration: TimeInterval = 1800) {
        precondition(capacity > 0 && duration > 0)
        self.capacity = capacity
        self.duration = duration
    }

    public mutating func append(_ reading: Reading) {
        guard reading.value.isFinite else { return }
        if let last = readings.last, reading.timestamp <= last.timestamp { return }
        readings.append(reading)
        readings.removeAll { reading.timestamp.timeIntervalSince($0.timestamp) > duration }
        if readings.count > capacity { readings.removeFirst(readings.count - capacity) }
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
