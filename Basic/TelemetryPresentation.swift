import CarGaugeCore

/// This target displays readings in the app only and creates no shared widget state.
@MainActor final class TelemetryPresentation {
    var hasActivity: Bool { false }
    var isForeground = false

    func cleanUpPreviousRun() {}
    func startActivity(source: DataSource, latestSample: @escaping @MainActor () -> (Reading, ThermalLevel)?,
                       onDeferredResult: @escaping @MainActor (Error?) -> Void) throws {
        throw ActivityUnavailable()
    }
    func endActivity() {}
    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) {}
    func markActivityStale() {}
    func clearWidget() {}

    private struct ActivityUnavailable: Error {}
}
