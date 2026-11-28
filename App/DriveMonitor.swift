import CarGaugeCore
import Combine
import Foundation

@MainActor final class DriveMonitor: ObservableObject {
    @Published private(set) var readings: [DriveSignal: DriveReading] = [:]
    @Published private(set) var fuel: FuelRate?
    @Published private(set) var fuelAt: Double?
    @Published private(set) var supported: [DriveSignal] = []
    @Published private(set) var storageError: String?
    @Published private(set) var automaticReport: DiagnosticReport?
    @Published var visibleSignals: Set<DriveSignal> {
        didSet { UserDefaults.standard.set(visibleSignals.map { Int($0.rawValue) }.sorted(), forKey: Self.signalsKey) }
    }

    let archive: TelemetryArchive
    let isFixture: Bool
    private var liveOwner: UUID?
    private var plan = VehiclePollPlan()
    private var startEvidence = EngineStartEvidence()
    private var nextPage: OBDSupportPage? = .pids01To20
    private var automatic: DiagnosticSurvey?
    private var lastAutomatic: ContinuousClock.Instant?
    private var scheduledOnLink = false
    private var pendingStart: Date?
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

    var masks: [OBDSupportPage: String] {
        var result: [OBDSupportPage: String] = [:]
        for (page, base) in [(OBDSupportPage.pids01To20, UInt8(0)), (.pids21To40, UInt8(32)), (.pids41To60, UInt8(64))] {
            if let mask = plan.masks[base] { result[page] = String(format: "%08X", mask) }
        }
        return result
    }

    func didConnect(owner: UUID) async {
        liveOwner = owner
        plan = VehiclePollPlan()
        startEvidence = EngineStartEvidence()
        nextPage = .pids01To20
        supported = []
        readings = [:]
        fuel = nil
        fuelAt = nil
        lastVoltage = nil
        pendingStart = nil
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
        for item in batch { readings[item.signal] = item }
        if let voltage = batch.first(where: { $0.signal == .ecuVoltage || $0.signal == .adapterVoltage }) {
            lastVoltage = voltage.monotonic
        }

        var linkFailure: Error?
        do {
            if !background, let page = nextPage {
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
            for signal in requests {
                let reading = try await client.readDriveSignal(signal)
                guard liveOwner == owner else { return }
                batch.append(reading)
                readings[signal] = reading
            }
        } catch {
            linkFailure = error
        }
        try Task.checkCancellation()
        guard liveOwner == owner else { return }

        let now = DriveClock.now
        let rpm = batch.first { $0.signal == .rpm && $0.quality == .received }
        let speed = batch.first { $0.signal == .speed && $0.quality == .received }
        let runtime = batch.first { $0.signal == .runTime && $0.quality == .received }
        if runtime != nil, let result = startEvidence.observe(runtime, rpm: rpm) { pendingStart = result }
        let estimate = linkFailure == nil && batch.contains { $0.signal == .map && $0.quality == .received }
            ? SpeedDensity.estimate(readings: readings, at: now, targetProfile: plan.isTargetProfile,
                                   calibration: currentCalibration)
            : nil
        fuel = estimate
        fuelAt = estimate == nil ? nil : now

        let frame = TripFrame(timestamp: .now, monotonic: now, readings: batch, rpm: rpm?.value,
                              speed: speed?.isFresh(at: now, within: 3) == true ? speed?.value : nil,
                              fuel: estimate, estimatedEngineStart: pendingStart)
        do {
            try await archive.record(owner: owner, frame: frame)
            if thermal != lastThermalLevel && (thermal != .normal || lastThermalLevel != nil) {
                try await archive.addEvent(kind: "temperature_state", payload: thermal.rawValue)
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

    func advanceDiagnostics(owner: UUID, client: ELM327Client, adapter: String?, firstObservation: Date?) async throws {
        guard liveOwner == owner else { return }
        if automatic == nil {
            let interval: Duration = scheduledOnLink ? .seconds(15 * 60) : .seconds(60)
            guard lastAutomatic.map({ $0.duration(to: .now) >= interval }) ?? true else { return }
            lastAutomatic = .now
            scheduledOnLink = true
            automatic = DiagnosticSurvey(firstObservedCoolantAt: firstObservation, adapterName: adapter,
                                         adapterIdentification: client.adapterIdentification, scope: .codesOnly)
        }
        guard let survey = automatic else { return }
        do {
            try await survey.performNext(with: client)
        } catch {
            if liveOwner == owner { await finalizeAutomatic(survey) }
            throw error
        }
        if liveOwner == owner, survey.report.state != .running { await finalizeAutomatic(survey) }
    }

    private func finalizeAutomatic(_ survey: DiagnosticSurvey) async {
        automatic = nil
        automaticReport = survey.report
        await store(survey.report, kind: "automatic_dtc")
    }

    func saveManual(_ report: DiagnosticReport) async {
        guard report.source == "vehicle" else { return }
        await store(report, kind: "manual_survey")
    }

    private func store(_ report: DiagnosticReport, kind: String) async {
        do {
            let json = try report.json(includeRaw: true)
            try await archive.addEvent(kind: kind, payload: String(decoding: json, as: UTF8.self), timestamp: report.startedAt)
            if kind == "automatic_dtc" {
                let statuses = DiagnosticCodeStatus.allCases.map { status in
                    let group = report.codes.first { $0.status == status }
                    let codes = group.map { Array(Set($0.replyGroups.flatMap { $0 })).sorted() }
                    let state = codes.map { $0.isEmpty ? "в ответе кодов нет" : $0.joined(separator: ", ") }
                        ?? "нет достоверного ответа"
                    return "\(status.title) · \(state)"
                }.joined(separator: "\n")
                let date = report.startedAt.formatted(date: .abbreviated, time: .shortened)
                try await archive.addEvent(kind: "dtc_summary", payload: "\(date)\n\(statuses)")
            }
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
        fuelAt = nil
        if let survey = automatic {
            survey.interrupt(reason)
            await finalizeAutomatic(survey)
        }
        do { try await archive.end(owner: owner, reason: reason, mayResume: mayResume) }
        catch { storageError = error.localizedDescription }
    }
}
