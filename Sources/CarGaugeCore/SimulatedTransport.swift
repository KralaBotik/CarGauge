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
    private let telemetryProfile: Bool

    public init(scenario: SimulationScenario = .warmup, latency: Duration = .milliseconds(35), telemetryProfile: Bool = false) {
        self.scenario = scenario
        self.latency = latency
        self.telemetryProfile = telemetryProfile
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
        if telemetryProfile {
            switch command {
            case "0100": return "4100BE3EB813\r>"
            case "0120": return "412080058011\r>"
            case "0140": return "4140BC000000\r>"
            case "0103": return "41030200\r>"
            case "010B": return "410B27\r>"
            case "010D": return "410D32\r>"
            case "010F": return "410F44\r>"
            case "011F": return String(format: "411F%04X\r>", min(65535, sample + 30))
            case "0142": return "NO DATA\r>"
            case "0144": return "41448000\r>"
            default: break
            }
        }
        switch command {
        case "ATZ": return "ELM327 v2.3\r>"
        case "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0": return "OK\r>"
        case "0100": return "410008100001\r>"
        case "0140": return scenario == .noVoltagePID ? "414000000000\r>" : "414040000000\r>"
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
        case "ATDPN": return "A6\r>"
        case "0101": return "410100076101\r>"
        case "0120": return "412000000001\r>"
        case "03": return "43010133\r>"
        case "07": return "4700\r>"
        case "0A": return "NO DATA\r>"
        case "020200": return "4202000133\r>"
        case "020000": return "42000008000000\r>"
        case "020500": return "4205007C\r>"
        case "ATRV": return "14.1V\r>"
        default: return "?\r>"
        }
    }
}
#endif
