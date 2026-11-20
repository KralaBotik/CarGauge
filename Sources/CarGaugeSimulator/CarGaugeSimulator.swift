import CarGaugeCore
import Foundation

@main struct CarGaugeSimulator {
    @MainActor static func main() async throws {
        let argument = CommandLine.arguments.dropFirst().first ?? "warmup"
        guard let scenario = SimulationScenario(rawValue: argument) else {
            print("Usage: cargauge-simulator [warmup|overheat|noVoltagePID|disconnect]")
            return
        }
        let transport = SimulatedTransport(scenario: scenario, latency: .zero)
        let client = ELM327Client(transport: transport)
        var monitor = OverheatMonitor()
        try await transport.connect()
        defer { transport.disconnect() }
        try await client.initialize()
        print("SIMULATOR • Hyundai Elantra HD / G4FC")
        for index in 0..<12 {
            do {
                let coolant = try await client.readCoolant()
                let snapshot = try await client.readSupplementary(source: .simulator, coolant: coolant)
                let level = monitor.update(coolant, at: Date())
                let rpm = snapshot.rpm.map { "\(Int($0.value)) rpm" } ?? "— rpm"
                let voltage = snapshot.voltage.map { "\($0.value) V [\(snapshot.voltageSource)]" } ?? "— V"
                print("\(index): \(Int(coolant.value)) °C, \(rpm), \(voltage) • \(level)")
            } catch {
                print("DISCONNECTED / stale: \(error.localizedDescription)")
                if scenario != .disconnect { throw error }
                break
            }
        }
    }
}
