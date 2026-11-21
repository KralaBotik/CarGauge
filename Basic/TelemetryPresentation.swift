import CarGaugeCore

/// This target displays readings in the app only and creates no shared widget state.
@MainActor final class TelemetryPresentation {
    var hasActivity: Bool { false }
    var isForeground = false

    func cleanUpPreviousRun() {}
    func startActivity(coolant: Reading, source: DataSource, level: ThermalLevel,
                       onDeferredResult: @escaping @MainActor (Error?) -> Void) throws {
        throw ActivityUnavailable()
    }
    func endActivity() {}
    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) async {}
    func markActivityStale() async {}
    func clearWidget() {}

    private struct ActivityUnavailable: Error {}
}
