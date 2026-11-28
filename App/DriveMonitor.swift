import CarGaugeCore
import Combine
import Foundation

@MainActor final class DriveMonitor: ObservableObject {
    @Published private(set) var readings: [DriveSignal: DriveReading] = [:]
    @Published private(set) var fuel: FuelRate?
    @Published private(set) var supported: [DriveSignal] = []
    @Published private(set) var storageError: String?
    @Published private(set) var automaticReport: DiagnosticReport?
    @Published var visibleSignals: Set<DriveSignal> {
        didSet { UserDefaults.standard.set(visibleSignals.map { Int($0.rawValue) }.sorted(), forKey: Self.signalsKey) }
    }

    let archive: TelemetryArchive
    let isFixture: Bool
    private var liveOwner: UUID?
    private var cooldownOwner: UUID?
    private var cooldown = OptionalPollCooldown()
    private var plan = VehiclePollPlan()
    private var startTracker = EngineStartTracker()
    private var nextPage: OBDSupportPage? = .pids01To20
    private var automatic: DiagnosticSurvey?
    private var lastAutomatic: ContinuousClock.Instant?
    private var scheduledOnLink = false
    private var connectedAt: Date?
    private var lastVoltage: Double?
    private var currentCalibration: Double = 1
    private var lastThermalLevel: ThermalLevel?
    private static let signalsKey = "carGauge-visible-signals-v1"

    init() {
        #if DEBUG
        isFixture = ProcessInfo.processInfo.arguments.contains("--telemetry-history-fixture")
        #else
        isFixture = false
        #endif
        let location = isFixture
            ? URL.temporaryDirectory.appending(path: "CarGauge-tests-\(UUID().uuidString)")
            : URL.applicationSupportDirectory.appending(path: "CarGauge")
        archive = TelemetryArchive(url: location.appending(path: "History.sqlite3"))
        if let saved = UserDefaults.standard.array(forKey: Self.signalsKey) as? [Int] {
            visibleSignals = Set(saved.compactMap { UInt8(exactly: $0).flatMap(DriveSignal.init(rawValue:)) })
        } else {
            visibleSignals = [.speed]
        }
    }

    var targetProfileConfirmed: Bool { plan.isTargetProfile }

    var masks: [OBDSupportPage: String] {
        var result: [OBDSupportPage: String] = [:]
        for (page, base) in [(OBDSupportPage.pids01To20, UInt8(0)), (.pids21To40, UInt8(32)), (.pids41To60, UInt8(64))] {
            if let mask = plan.masks[base] { result[page] = String(format: "%08X", mask) }
        }
        return result
    }

    func didConnect(owner: UUID, at date: Date) async {
        liveOwner = owner
        if cooldownOwner != owner {
            cooldown = OptionalPollCooldown()
            cooldownOwner = owner
        }
        plan = VehiclePollPlan()
        startTracker = EngineStartTracker()
        nextPage = .pids01To20
        supported = []
        readings = [:]
        fuel = nil
        lastVoltage = nil
        connectedAt = date
        lastThermalLevel = nil
        automatic = nil
        scheduledOnLink = false
        do {
            let calibration = try await archive.calibration()
            if liveOwner == owner { currentCalibration = calibration.factor }
        } catch {
            storageError = error.localizedDescription
        }
    }

    func shouldReadVoltage(at time: Double) -> Bool {
        guard let lastVoltage else { return true }
        return time - lastVoltage >= 4
    }

    func settingCalibration(_ calibration: FuelCalibrationState) { currentCalibration = calibration.factor }

    func capture(owner: UUID, client: ELM327Client, background: Bool, thermal: ThermalLevel) async throws {
        guard liveOwner == owner else { return }
        var batch = Array(client.latestDriveReadings.values)
        if client.latestDriveReadings[.rpm] == nil {
            batch.append(DriveReading(signal: .rpm, value: nil, bytes: [], timestamp: .now,
                                      monotonic: DriveClock.now, quality: .noData))
        }
        for item in batch { readings[item.signal] = item }
        if readings[.rpm]?.quality != .received || (readings[.rpm]?.value ?? 0) <= 0 { fuel = nil }
        if let voltage = batch.first(where: { $0.signal == .ecuVoltage || $0.signal == .adapterVoltage }) {
            lastVoltage = voltage.monotonic
        }

        var linkFailure: Error?
        var optionalCommand: String?
        do {
            if !background, let page = nextPage, cooldown.allows(page.rawValue, at: DriveClock.now) {
                optionalCommand = page.rawValue
                let result = try await client.probeSupport(page)
                guard liveOwner == owner else { return }
                nextPage = nil
                if let result {
                    plan.record(page: page, bits: result.bits)
                    if result.bits & 1 != 0 {
                        switch page {
                        case .pids01To20: nextPage = .pids21To40
                        case .pids21To40: nextPage = .pids41To60
                        case .pids41To60: break
                        }
                    }
                    supported = DriveSignal.allCases.filter(plan.supports)
                }
            }
            let requests = plan.next(at: DriveClock.now, background: background)
            for signal in requests where cooldown.allows(signal.command, at: DriveClock.now) {
                optionalCommand = signal.command
                let reading = try await client.readDriveSignal(signal)
                guard liveOwner == owner else { return }
                batch.append(reading)
                readings[signal] = reading
                if [.map, .intake, .fuelStatus, .commandedLambda].contains(signal),
                   SpeedDensity.estimate(readings: readings, at: DriveClock.now,
                                         targetProfile: plan.isTargetProfile, calibration: currentCalibration) == nil {
                    fuel = nil
                }
            }
        } catch {
            if error as? OBDError == .timeout, let command = optionalCommand, liveOwner == owner {
                cooldown.timedOut(command, at: DriveClock.now)
            }
            linkFailure = error
        }
        try Task.checkCancellation()
        guard liveOwner == owner else { return }

        let now = DriveClock.now
        let rpm = batch.first { $0.signal == .rpm && $0.quality == .received }
        let speed = batch.first { $0.signal == .speed && $0.quality == .received }
        let runtime = batch.first { $0.signal == .runTime }
        if startTracker.update(runtime: runtime, rpm: rpm, at: now) {
            do { try await archive.end(owner: owner, reason: "runtime_reset", mayResume: true) }
            catch { storageError = error.localizedDescription }
            guard liveOwner == owner, !Task.isCancelled else { return }
        }
        let estimate = linkFailure == nil && batch.contains { $0.signal == .map && $0.quality == .received }
            ? SpeedDensity.estimate(readings: readings, at: now, targetProfile: plan.isTargetProfile,
                                   calibration: currentCalibration)
            : nil
        fuel = estimate

        let frame = TripFrame(timestamp: .now, monotonic: now, readings: batch, rpm: rpm?.value,
                              speed: speed?.isFresh(at: now, within: 3) == true ? speed?.value : nil,
                              fuel: estimate, estimatedEngineStart: startTracker.estimate, connectedAt: connectedAt)
        do {
            try await archive.record(owner: owner, frame: frame)
            if thermal != lastThermalLevel && (thermal != .normal || lastThermalLevel != nil) {
                try await archive.addEvent(kind: "temperature_state", payload: thermal.rawValue, owner: owner)
            }
            if liveOwner == owner {
                lastThermalLevel = thermal
                storageError = nil
            }
        } catch {
            storageError = error.localizedDescription
        }
        if let linkFailure { throw linkFailure }
    }

    func captureInterruptedPrimary(owner: UUID, client: ELM327Client) async {
        guard liveOwner == owner, let coolant = client.latestDriveReadings[.coolant] else { return }
        let frame = TripFrame(timestamp: .now, monotonic: DriveClock.now,
                              readings: [coolant], rpm: nil, speed: nil, fuel: nil)
        do { try await archive.record(owner: owner, frame: frame) }
        catch { storageError = error.localizedDescription }
    }

    func advanceDiagnostics(owner: UUID, client: ELM327Client, adapter: String?, firstObservation: Date?,
                            source: DataSource) async throws {
        guard liveOwner == owner else { return }
        if automatic == nil {
            let interval: Duration = scheduledOnLink ? .seconds(15 * 60) : .seconds(60)
            guard lastAutomatic.map({ $0.duration(to: .now) >= interval }) ?? true else { return }
            lastAutomatic = .now
            scheduledOnLink = true
            automatic = DiagnosticSurvey(firstObservedCoolantAt: firstObservation, adapterName: adapter,
                                         adapterIdentification: client.adapterIdentification, source: source, scope: .codesOnly)
        }
        guard let survey = automatic else { return }
        do {
            try await survey.performNext(with: client)
        } catch {
            if liveOwner == owner { await finalizeAutomatic(survey, owner: owner) }
            throw error
        }
        if liveOwner == owner, survey.report.state != .running { await finalizeAutomatic(survey, owner: owner) }
    }

    private func finalizeAutomatic(_ survey: DiagnosticSurvey, owner: UUID) async {
        automatic = nil
        await store(survey.report, kind: "automatic_dtc", owner: owner)
        automaticReport = survey.report
    }

    func saveManual(_ report: DiagnosticReport) async {
        guard report.source == "vehicle" else { return }
        await store(report, kind: "manual_survey")
    }

    private func store(_ report: DiagnosticReport, kind: String, owner: UUID? = nil) async {
        do {
            try await archive.saveDiagnostic(report, owner: owner)
            let json = try report.json(includeRaw: true)
            var summary: String?
            if kind == "automatic_dtc" {
                let statuses = DiagnosticCodeStatus.allCases.map { status in
                    let group = report.codes.first { $0.status == status }
                    let codes = group.map { Array(Set($0.replyGroups.flatMap { $0 })).sorted() }
                    let state = codes.map { $0.isEmpty ? "в ответе кодов нет" : $0.joined(separator: ", ") }
                        ?? "нет достоверного ответа"
                    return "\(status.title) · \(state)"
                }.joined(separator: "\n")
                let date = report.startedAt.formatted(date: .abbreviated, time: .shortened)
                summary = "\(date)\n\(statuses)"
            }
            try await archive.addEvent(kind: kind, payload: String(decoding: json, as: UTF8.self), timestamp: report.startedAt,
                                       owner: owner, summary: summary)
        } catch {
            storageError = error.localizedDescription
        }
    }

    func lose(owner: UUID, reason: String, mayResume: Bool = false) async {
        guard liveOwner == owner else {
            if !mayResume {
                do { try await archive.end(owner: owner, reason: reason) }
                catch { storageError = error.localizedDescription }
            }
            return
        }
        liveOwner = nil
        readings = [:]
        fuel = nil
        if let survey = automatic {
            survey.interrupt(reason)
            await finalizeAutomatic(survey, owner: owner)
        }
        do { try await archive.end(owner: owner, reason: reason, mayResume: mayResume) }
        catch { storageError = error.localizedDescription }
    }
}
