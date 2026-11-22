import Foundation

public enum VehicleSessionPolicy {
    public static let maximumBackgroundTime: TimeInterval = 30 * 60
    public static let maximumSessionTime: TimeInterval = 4 * 60 * 60

    public static func pollInterval(inBackground: Bool) -> Duration {
        inBackground ? .seconds(2) : .seconds(1)
    }
}

public struct VehicleRetryBudget: Sendable {
    private var failures = 0
    private var healthyCycles = 0

    public init() {}

    public mutating func didCompleteCycle() {
        guard failures > 0 else { return }
        healthyCycles += 1
        if healthyCycles >= 10 { failures = 0 }
    }

    public mutating func nextDelay(inForeground: Bool) -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8]
        healthyCycles = 0
        failures += 1
        guard inForeground, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }
}

/// Park on continuous fresh zero RPM. Give an ignition-only start more time for cranking.
public struct EngineIdleMonitor: Sendable {
    private var hasRun = false
    private var firstZero: Date?
    private var previousZero: Date?

    public init() {}

    public mutating func shouldPark(after speed: Reading?, at now: Date) -> Bool {
        guard let speed, speed.isFresh(at: now), speed.value >= 0 else {
            clearZeroSamples()
            return false
        }
        if speed.value > 0 {
            hasRun = true
            clearZeroSamples()
            return false
        }
        if let previousZero, speed.timestamp <= previousZero { return false }
        if let previousZero, !Reading(0, at: previousZero).isFresh(at: speed.timestamp) { clearZeroSamples() }
        if firstZero == nil { firstZero = speed.timestamp }
        previousZero = speed.timestamp
        let grace: TimeInterval = hasRun ? 15 : 45
        return firstZero.map { speed.timestamp.timeIntervalSince($0) >= grace } ?? false
    }

    public mutating func interrupt() {
        clearZeroSamples()
    }

    private mutating func clearZeroSamples() {
        firstZero = nil
        previousZero = nil
    }
}
