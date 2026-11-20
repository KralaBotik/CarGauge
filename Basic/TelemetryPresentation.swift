import CarGaugeCore

/// This target displays readings in the app only and creates no shared widget state.
@MainActor final class TelemetryPresentation {
    var hasActivity: Bool { false }

    func cleanUpPreviousRun() {}
    func startActivity(coolant: Reading, source: DataSource, level: ThermalLevel) throws {
        throw ActivityUnavailable()
    }
    func endActivity() {}
    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) async {}
    func markActivityStale() async {}
    func clearWidget() {}

    private struct ActivityUnavailable: Error {}
}
