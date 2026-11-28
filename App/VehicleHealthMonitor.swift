import CarGaugeCore
import Combine
import Foundation
import UserNotifications

@MainActor final class VehicleHealthMonitor: ObservableObject {
    @Published private(set) var update: MonitoringUpdate?
    @Published private(set) var openIssues: [MonitoringEvent] = []
    @Published private(set) var voltageReference: VoltageReference?
    @Published private(set) var savedBaselines: [MonitoringBaselineInfo] = []
    @Published private(set) var enabledOverrides: [String: Bool] = [:]
    @Published private(set) var errorMessage: String?
    @Published var notifyDiagnostics = UserDefaults.standard.bool(forKey: "notifyDiagnostics") {
        didSet { UserDefaults.standard.set(notifyDiagnostics, forKey: "notifyDiagnostics") }
    }
    @Published var criticalOnly = UserDefaults.standard.bool(forKey: "diagnosticCriticalOnly") {
        didSet { UserDefaults.standard.set(criticalOnly, forKey: "diagnosticCriticalOnly") }
    }

    let archive: TelemetryArchive
    let rules = MonitoringProfile.g4fc.rules
    private var engine = MonitoringEngine()
    private var loading = false
    private var ready = false
    private var saving = false
    private var saveAgain = false
    private var lastSave: Double?
    private var saveDeferredUntil = 0.0
    private var pending: [MonitoringEvent] = []
    private var activeOwner: UUID?
    private var scan: (UUID, DiagnosticReport, Double)?
    private var freshZero: Double?
    private var hadRPM = false

    init(archive: TelemetryArchive) { self.archive = archive }

    func prepare() async {
        guard !ready, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let checkpoint = try await archive.monitoringCheckpoint()
            let reference = try await archive.voltageReference()
            engine = MonitoringEngine(rules: rules, checkpoint: checkpoint)
            voltageReference = reference
            ready = true
            refreshCheckpointState()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func begin(owner: UUID) {
        activeOwner = owner
        freshZero = nil
        hadRPM = false
        scan = nil
        engine.interrupt()
        update = nil
    }

    func interrupt(owner: UUID) async {
        guard activeOwner == owner else { return }
        activeOwner = nil
        freshZero = nil
        hadRPM = false
        scan = nil
        engine.interrupt()
        update = nil
        if ready { await persist(at: DriveClock.now, force: true) }
    }

    func enabled(_ rule: MonitoringRule) -> Bool { enabledOverrides[rule.id] ?? rule.enabledByDefault }

    func setEnabled(_ enabled: Bool, rule: MonitoringRule) async {
        await prepare()
        guard ready else { return }
        engine.setEnabled(enabled, ruleID: rule.id)
        refreshCheckpointState()
        await persist(at: DriveClock.now, force: true)
    }

    func setVoltage(adapter: Double, meter: Double) async {
        guard let reference = VoltageReference(adapter: adapter, multimeter: meter) else {
            errorMessage = "Проверьте два одновременных значения напряжения."
            return
        }
        do {
            try await archive.setVoltageReference(reference)
            voltageReference = reference
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func clearVoltageReference() async {
        do {
            try await archive.setVoltageReference(nil)
            voltageReference = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func evaluate(owner: UUID, readings: [DriveSignal: DriveReading], telemetry: TripFrame,
                  tripID: Int64?, thresholds: ThermalThresholds) async {
        guard activeOwner == owner else { return }
        await prepare()
        guard ready, activeOwner == owner else { return }
        let now = telemetry.monotonic
        let freshRPM = readings[.rpm].flatMap { $0.isFresh(at: now, within: 3) ? $0 : nil }
        let explicitStart: Bool
        if freshRPM?.value == 0 {
            freshZero = freshRPM?.monotonic
            hadRPM = false
            explicitStart = false
        } else if let rpm = freshRPM, let value = rpm.value, value > 0 {
            explicitStart = !hadRPM && (freshZero.map { rpm.monotonic > $0 && rpm.monotonic - $0 <= 5 } ?? false)
            hadRPM = true
            freshZero = nil
        } else {
            freshZero = nil
            explicitStart = false
        }
        let freshScan = scan.flatMap { $0.0 == owner && now - $0.2 <= 20 * 60 ? $0.1 : nil }
        let codes = Set(freshScan?.codes.flatMap { $0.replyGroups.flatMap { $0 } } ?? [])
        let positive = Set(freshScan?.codes.filter { $0.replyGroups.count == 1 }.map(\.status) ?? [])
        let knownCoverage = freshScan?.state == .completed && positive.contains(.stored) && positive.contains(.pending)
        let frame = MonitoringFrame(timestamp: telemetry.timestamp, monotonic: now, readings: readings, tripID: tripID,
                                    engineStartObserved: explicitStart, activeDTCs: codes,
                                    fuelLitresPer100km: telemetry.fuel?.litresPer100km(speed: telemetry.speed),
                                    thermalThresholds: thresholds, dtcCoverageKnown: knownCoverage,
                                    adapterVoltageOffset: voltageReference?.offset)
        let state = engine.evaluate(frame)
        update = state
        if !state.events.isEmpty {
            pending += state.events
            refreshCheckpointState()
        }
        await persist(at: now, force: !state.events.isEmpty)
    }

    func recordedScan(_ report: DiagnosticReport, owner: UUID?) async {
        if let owner, activeOwner == owner, report.state == .completed { scan = (owner, report, DriveClock.now) }
        guard notifyDiagnostics, !criticalOnly, report.source == "vehicle",
              report.state == .completed,
              report.codes.contains(where: { $0.status == .stored && !$0.replyGroups.isEmpty }) else { return }
        do {
            for item in try await archive.dtcFindings()
                where item.status == .stored && item.lastSeen == report.startedAt && item.notReportedAt == nil {
                let title = "Код двигателя \(item.code)"
                let text = DTCCatalog.lookup(item.code)?.title ?? "ЭБУ сообщил сохранённый код. Откройте диагностику."
                await post(id: "health-dtc-\(item.id)-\(item.appearances)", title: title, message: text)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshCheckpointState() {
        let checkpoint = engine.checkpoint
        enabledOverrides = checkpoint.enabledOverrides
        savedBaselines = checkpoint.baselines
        openIssues = checkpoint.openIssues.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func persist(at now: Double, force: Bool) async {
        if saving {
            if force { saveAgain = true }
            return
        }
        guard now >= saveDeferredUntil,
              force || !pending.isEmpty || (lastSave.map { now - $0 >= 60 } ?? true) else { return }
        saving = true
        defer {
            saving = false
            if saveAgain {
                saveAgain = false
                Task { await persist(at: DriveClock.now, force: true) }
            }
        }
        let batch = pending
        let checkpoint = engine.checkpoint
        do {
            try await archive.saveMonitoring(checkpoint, events: batch)
            let ids = Set(batch.map(\.id))
            pending.removeAll { ids.contains($0.id) }
            lastSave = now
            errorMessage = nil
            if notifyDiagnostics {
                for event in batch where event.kind == .problem && event.shouldNotify
                    && event.ruleID != "coolant.critical" && event.ruleID != "coolant.warning"
                    && (!criticalOnly || event.severity == .critical) {
                    await post(id: "health-rule-\(event.issueID.uuidString)",
                        title: rules.first { $0.id == event.ruleID }?.title ?? event.ruleID,
                        message: "Подтверждено условие правила. Подробности в CarGauge.")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            saveDeferredUntil = now + 5
        }
    }

    private func post(id: String, title: String, message: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        do {
            guard try await archive.reserveNotice(id, at: .now) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
            catch {
                try? await archive.releaseNotice(id)
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
