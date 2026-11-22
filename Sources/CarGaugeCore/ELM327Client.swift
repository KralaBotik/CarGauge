import Foundation

public enum SupplementarySensor: Hashable, Sendable {
    case rpm, voltage
}

public struct SupplementaryTimeout: LocalizedError, Sendable {
    public let sensor: SupplementarySensor
    public var errorDescription: String? {
        sensor == .rpm ? "Истекло время ожидания оборотов" : "Истекло время ожидания напряжения"
    }
}

@MainActor public final class ELM327Client {
    public static let initializationCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]
    private let transport: any OBDTransport
    private var voltageSource: VoltageSource = .ecu
    private var rpmSupported = true
    private var voltageSupported = true
    private var rpmRetryAfter: Date?
    private var voltageRetryAfter: Date?
    private var sequenceInProgress = false
    private var initialCoolant: Reading?

    public init(transport: any OBDTransport) { self.transport = transport }

    public func initialize() async throws {
        try beginSequence()
        defer { sequenceInProgress = false }
        initialCoolant = nil
        voltageSource = .ecu
        rpmSupported = true
        voltageSupported = true
        rpmRetryAfter = nil
        voltageRetryAfter = nil
        for command in Self.initializationCommands {
            try Task.checkCancellation()
            let response = try await transport.exchange(command, timeout: 5)
            let lines = try OBDDecoder.lines(response, echo: command)
            if command == "ATZ" {
                guard lines.contains(where: { $0.contains("ELM327") }) else { throw OBDError.malformedResponse }
            } else {
                guard lines == ["OK"] else { throw OBDError.malformedResponse }
            }
        }
        // The first OBD request may perform a slow automatic protocol search.
        let value = try OBDDecoder.decode(.coolant, response: await transport.exchange("0105", timeout: 15))
        try Task.checkCancellation()
        initialCoolant = Reading(value, at: Date())
    }

    public func readCoolant() async throws -> Reading {
        try beginSequence()
        defer { sequenceInProgress = false }
        if let initialCoolant {
            self.initialCoolant = nil
            if initialCoolant.isFresh(at: Date()) { return initialCoolant }
        }
        let value = try await read(.coolant)
        try Task.checkCancellation()
        return Reading(value, at: Date())
    }

    /// Coolant is published first by the caller; slow optional sensors never hide it.
    public func readSupplementary(source: DataSource, coolant: Reading,
                                  skipping sensors: Set<SupplementarySensor> = []) async throws -> TelemetrySnapshot {
        try beginSequence()
        defer { sequenceInProgress = false }
        var rpm: Reading?
        if rpmSupported && !sensors.contains(.rpm) && (rpmRetryAfter.map { $0 <= Date() } ?? true) {
            let response = try await exchangeOptional(OBDPID.rpm.rawValue, sensor: .rpm)
            do {
                rpm = Reading(try OBDDecoder.decode(.rpm, response: response), at: Date())
                rpmRetryAfter = nil
            } catch OBDError.unsupported {
                rpmSupported = false
            } catch let error as OBDError where error.isMissingSample {
                rpmRetryAfter = Date().addingTimeInterval(10)
            }
        }
        var voltage: Reading?
        if voltageSupported && !sensors.contains(.voltage) && (voltageRetryAfter.map { $0 <= Date() } ?? true) {
            if voltageSource == .ecu {
                let response = try await exchangeOptional(OBDPID.moduleVoltage.rawValue, sensor: .voltage)
                do {
                    voltage = Reading(try OBDDecoder.decode(.moduleVoltage, response: response), at: Date())
                } catch let error as OBDError where error.isMissingSample || error == .unsupported {
                    voltageSource = .adapter
                }
            }
            if voltageSource == .adapter {
                let response = try await exchangeOptional("ATRV", sensor: .voltage)
                do {
                    voltage = Reading(try OBDDecoder.adapterVoltage(response), at: Date())
                } catch OBDError.unsupported {
                    voltageSupported = false
                } catch let error as OBDError where error.isMissingSample {
                    voltageRetryAfter = Date().addingTimeInterval(10)
                }
            }
        }
        try Task.checkCancellation()
        return TelemetrySnapshot(source: source, coolant: coolant, rpm: rpm, voltage: voltage, voltageSource: voltageSource)
    }

    private func exchangeOptional(_ command: String, sensor: SupplementarySensor) async throws -> String {
        do {
            return try await transport.exchange(command, timeout: 3)
        } catch OBDError.timeout {
            // The link still needs a fresh handshake. The caller can omit this sensor on the new link.
            throw SupplementaryTimeout(sensor: sensor)
        }
    }

    private func beginSequence() throws {
        try Task.checkCancellation()
        guard !sequenceInProgress else { throw OBDError.busy }
        sequenceInProgress = true
    }

    private func read(_ pid: OBDPID) async throws -> Double {
        try Task.checkCancellation()
        return try OBDDecoder.decode(pid, response: await transport.exchange(pid.rawValue, timeout: 3))
    }
}
