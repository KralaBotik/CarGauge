import Foundation

public enum VehicleSessionPolicy {
    public static let maximumBackgroundTime: TimeInterval = 30 * 60
    public static let healthySamplesBeforeReset = 10

    public static func initialSource(hasSavedAdapter: Bool, launchesSimulator: Bool) -> DataSource {
        hasSavedAdapter && !launchesSimulator ? .vehicle : .simulator
    }

    public static func retryDelay(afterConsecutiveFailures failures: Int, inForeground: Bool) -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8]
        guard inForeground, failures > 0, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }
}

/// Park only after seeing this session's engine run and then receiving fresh zero-RPM samples.
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
        guard hasRun else { return false }
        if let previousZero, speed.timestamp <= previousZero { return false }
        if let previousZero, !Reading(0, at: previousZero).isFresh(at: speed.timestamp) { clearZeroSamples() }
        if firstZero == nil { firstZero = speed.timestamp }
        previousZero = speed.timestamp
        return firstZero.map { speed.timestamp.timeIntervalSince($0) >= 15 } ?? false
    }

    private mutating func clearZeroSamples() {
        firstZero = nil
        previousZero = nil
    }
}
