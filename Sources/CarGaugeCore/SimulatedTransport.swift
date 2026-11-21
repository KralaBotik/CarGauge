#if DEBUG || !os(iOS)
import Foundation

public enum SimulationScenario: String, CaseIterable, Sendable {
    case warmup, overheat, noVoltagePID, disconnect, reconnect, missingCoolant, invalidCoolant, hangingAdapter, engineOff
}

/// Deterministic ELM emulator. It returns text through the same decoder as BLE.
@MainActor public final class SimulatedTransport: OBDTransport {
    private var session: UUID?
    private var inFlight = false
    private var sample = 0
    private let scenario: SimulationScenario
    private let latency: Duration

    public init(scenario: SimulationScenario = .warmup, latency: Duration = .milliseconds(35)) {
        self.scenario = scenario
        self.latency = latency
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard session == nil else { throw OBDError.busy }
        session = UUID()
        sample = 0
    }

    public func disconnect() {
        session = nil
        inFlight = false
    }

    public func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        guard let session else { throw OBDError.disconnected }
        guard !inFlight else { throw OBDError.busy }
        inFlight = true
        defer { if self.session == session { inFlight = false } }
        let limit = Duration.seconds(timeout)
        let hangs = scenario == .hangingAdapter && command == "0105" && sample > 0
        do {
            try await Task.sleep(for: hangs ? limit : min(latency, limit))
        } catch {
            if self.session == session { disconnect() }
            throw error
        }
        guard self.session == session else { throw OBDError.disconnected }
        guard latency < limit, !hangs else {
            disconnect()
            throw OBDError.timeout
        }
        switch command {
        case "ATZ": return "ELM327 v2.3\r>"
        case "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0": return "OK\r>"
        case "0105":
            sample += 1
            if (scenario == .disconnect || scenario == .reconnect) && sample > 6 {
                disconnect()
                throw OBDError.disconnected
            }
            if sample > 2 && scenario == .missingCoolant { return "NO DATA\r>" }
            if sample > 2 && scenario == .invalidCoolant { return "4105GZ\r>" }
            let temperature = scenario == .overheat ? min(120, 98 + sample * 2) : min(92, 18 + sample * 2)
            return String(format: "4105%02X\r>", temperature + 40)
        case "010C":
            let speed = scenario == .engineOff && sample > 3 ? 0 : max(800, 1400 - sample * 15)
            return String(format: "410C%04X\r>", speed * 4)
        case "0142": return scenario == .noVoltagePID ? "NO DATA\r>" : "41423778\r>"
        case "ATRV": return "14.1V\r>"
        default: return "?\r>"
        }
    }
}
#endif
