import Foundation

public enum SupplementarySensor: Hashable, Sendable {
    case rpm, voltage
}

public enum SupplementaryTimeout: LocalizedError, Sendable {
    case rpm, ecuVoltage, adapterVoltage

    public var sensor: SupplementarySensor { self == .rpm ? .rpm : .voltage }

    public var errorDescription: String? {
        switch self {
        case .rpm: "Истекло время ожидания оборотов"
        case .ecuVoltage: "ЭБУ не ответил на запрос напряжения"
        case .adapterVoltage: "Адаптер не ответил на запрос напряжения"
        }
    }
}

/// Carries recovery choices across new links in the same measurement run.
public struct SupplementaryRecovery: Sendable {
    public private(set) var initialVoltageSource: VoltageSource = .ecu
    public private(set) var skippedSensors: Set<SupplementarySensor> = []

    public init() {}

    public mutating func record(_ timeout: SupplementaryTimeout) {
        if timeout == .ecuVoltage {
            initialVoltageSource = .adapter
        } else {
            skippedSensors.insert(timeout.sensor)
        }
    }
}

@MainActor public final class ELM327Client {
    public static let initializationCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]
    public static let allowedCommands = Set(initializationCommands + OBDPID.allCases.map(\.rawValue)
                                            + OBDSupportPage.allCases.map(\.rawValue) + ["ATRV"]).union(DiagnosticRequest.allowed).union(DriveSignal.extra.map(\.command))

    private let transport: any OBDTransport
    private var voltageSource: VoltageSource = .ecu
    private var rpmSupported = true
    private var voltageSupported = true
    private var rpmRetryAfter: Date?
    private var voltageRetryAfter: Date?
    private var sequenceInProgress = false
    private var initialCoolant: Reading?
    public private(set) var adapterIdentification: String?
    public private(set) var latestDriveReadings: [DriveSignal: DriveReading] = [:]

    public init(transport: any OBDTransport) { self.transport = transport }

    public func initialize(voltageSource: VoltageSource = .ecu) async throws {
        try beginSequence()
        defer { sequenceInProgress = false }
        initialCoolant = nil
        latestDriveReadings.removeAll()
        adapterIdentification = nil
        self.voltageSource = voltageSource
        rpmSupported = true
        voltageSupported = true
        rpmRetryAfter = nil
        voltageRetryAfter = nil
        for command in Self.initializationCommands {
            try Task.checkCancellation()
            let response = try await transport.exchange(command, timeout: 5)
            let lines = try OBDDecoder.lines(response, echo: command)
            if command == "ATZ" {
                guard let banner = lines.first(where: { $0.contains("ELM327") }) else {
                    throw OBDError.malformedResponse
                }
                adapterIdentification = String(banner.prefix(128))
            } else {
                guard lines == ["OK"] else { throw OBDError.malformedResponse }
            }
        }
        // The first OBD request may perform a slow automatic protocol search.
        initialCoolant = try await readPrimary(.coolant, signal: .coolant, timeout: 15)
    }

    public func readCoolant() async throws -> Reading {
        try beginSequence()
        defer { sequenceInProgress = false }
        if let initialCoolant {
            self.initialCoolant = nil
            if initialCoolant.isFresh(at: Date()) { return initialCoolant }
        }
        return try await readPrimary(.coolant, signal: .coolant, timeout: 3)
    }

    /// Discovery is optional and may report nothing on healthy cars. A timed-out request
    /// still invalidates the link, so transport failures are propagated to the session.
    public func probeSupport(_ page: OBDSupportPage) async throws -> OBDSupportMask? {
        try beginSequence()
        defer { sequenceInProgress = false }
        let response = try await transport.exchange(page.rawValue, timeout: 2)
        try Task.checkCancellation()
        do {
            return try OBDDecoder.supportMask(page, response: response)
        } catch let error as OBDError where error.isMissingSample || error == .unsupported {
            // A missing, malformed, or unsupported mask is advisory. Explicit ELM and
            // bus errors still leave the adapter session in an unknown state.
            return nil
        }
    }

    /// Coolant is published first by the caller; slow optional sensors never hide it.
    public func readSupplementary(source: DataSource, coolant: Reading,
                                  skipping sensors: Set<SupplementarySensor> = [],
                                  includeVoltage: Bool = true) async throws -> TelemetrySnapshot {
        try beginSequence()
        defer { sequenceInProgress = false }
        var rpm: Reading?
        latestDriveReadings[.rpm] = nil
        latestDriveReadings[.ecuVoltage] = nil
        latestDriveReadings[.adapterVoltage] = nil
        if rpmSupported && !sensors.contains(.rpm) && (rpmRetryAfter.map { $0 <= Date() } ?? true) {
            let response = try await exchangeOptional(OBDPID.rpm.rawValue, timeoutFailure: .rpm)
            do {
                rpm = try acceptPrimary(.rpm, signal: .rpm, response: response)
                rpmRetryAfter = nil
            } catch OBDError.unsupported {
                rpmSupported = false
            } catch let error as OBDError where error.isMissingSample {
                rpmRetryAfter = Date().addingTimeInterval(10)
            }
        }
        var voltage: Reading?
        if includeVoltage && voltageSupported && !sensors.contains(.voltage) && (voltageRetryAfter.map { $0 <= Date() } ?? true) {
            if voltageSource == .ecu {
                let response = try await exchangeOptional(OBDPID.moduleVoltage.rawValue, timeoutFailure: .ecuVoltage)
                do {
                    voltage = try acceptPrimary(.moduleVoltage, signal: .ecuVoltage, response: response)
                } catch let error as OBDError where error.isMissingSample || error == .unsupported {
                    voltageSource = .adapter
                }
            }
            if voltageSource == .adapter {
                let response = try await exchangeOptional("ATRV", timeoutFailure: .adapterVoltage)
                do {
                    let value = try OBDDecoder.adapterVoltage(response)
                    let reading = Reading(value, at: .now)
                    voltage = reading
                    latestDriveReadings[.adapterVoltage] = DriveReading(signal: .adapterVoltage, value: value,
                        bytes: Array(response.utf8), timestamp: reading.timestamp, monotonic: DriveClock.now)
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

    func exchangeDiagnostic(_ request: DiagnosticRequest) async throws -> String {
        try beginSequence()
        defer { sequenceInProgress = false }
        return try await transport.exchange(request.wire, timeout: 2)
    }

    private func exchangeOptional(_ command: String, timeoutFailure: SupplementaryTimeout) async throws -> String {
        do {
            return try await transport.exchange(command, timeout: 3)
        } catch OBDError.timeout {
            // A timeout invalidates the link. Any fallback starts after a fresh handshake.
            throw timeoutFailure
        }
    }

    private func beginSequence() throws {
        try Task.checkCancellation()
        guard !sequenceInProgress else { throw OBDError.busy }
        sequenceInProgress = true
    }

    public func readDriveSignal(_ signal: DriveSignal) async throws -> DriveReading {
        guard DriveSignal.extra.contains(signal), Self.allowedCommands.contains(signal.command) else { throw OBDError.unsupported }
        try beginSequence()
        defer { sequenceInProgress = false }
        let response = try await transport.exchange(signal.command, timeout: 2)
        try Task.checkCancellation()
        let now = Date()
        let monotonic = DriveClock.now
        let quality: DriveReading.Quality
        do {
            return try DriveReading.decode(signal, response: response, timestamp: now, monotonic: monotonic)
        } catch OBDError.noData {
            quality = .noData
        } catch OBDError.unsupported {
            quality = .unsupported
        } catch OBDError.malformedResponse {
            quality = .malformed
        } catch OBDError.ambiguousResponse {
            quality = .ambiguous
        } catch DiagnosticWireError.negative {
            quality = .unsupported
        }
        return DriveReading(signal: signal, value: nil, bytes: Array(response.utf8), timestamp: now,
                            monotonic: monotonic, quality: quality)
    }

    private func readPrimary(_ pid: OBDPID, signal: DriveSignal, timeout: TimeInterval) async throws -> Reading {
        let response = try await transport.exchange(pid.rawValue, timeout: timeout)
        try Task.checkCancellation()
        return try acceptPrimary(pid, signal: signal, response: response)
    }

    private func acceptPrimary(_ pid: OBDPID, signal: DriveSignal, response: String) throws -> Reading {
        let value = try OBDDecoder.decode(pid, response: response)
        let received = Date()
        let monotonic = DriveClock.now
        do {
            latestDriveReadings[signal] = try DriveReading.decode(signal, response: response, timestamp: received, monotonic: monotonic)
        } catch {
            // Equal anonymous answers can still support the established dashboard decoder.
            // They do not provide a unique input to the fuel model.
            latestDriveReadings[signal] = DriveReading(signal: signal, value: value, bytes: Array(response.utf8),
                timestamp: received, monotonic: monotonic, quality: .ambiguous)
        }
        return Reading(value, at: received)
    }
}
