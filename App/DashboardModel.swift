import CarGaugeCore
import Combine
import Foundation
import UserNotifications

enum MeasurementPhase {
    case idle, awaitingAdapter, connecting, streaming, retrying, failed, stopped, parked
}

@MainActor final class DashboardModel: ObservableObject {
    @Published private(set) var source: DataSource = .simulator
    @Published private(set) var coolant: Reading?
    @Published private(set) var supplementary: TelemetrySnapshot?
    @Published private(set) var history: [WarmupHistory.Point] = []
    @Published private(set) var level: ThermalLevel = .normal
    @Published private(set) var phase: MeasurementPhase = .idle
    @Published private(set) var thresholds: ThermalThresholds
    @Published private(set) var status = "Ожидание запуска"
    @Published private(set) var isRunning = false
    @Published private(set) var ble = BLETransport()
    @Published private(set) var activityIsRunning = false
    @Published var presentationMessage: String?
    @Published var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }
    #if !CARGAUGE_BASIC
    @Published var autoLiveActivity = UserDefaults.standard.bool(forKey: "autoLiveActivity") {
        didSet {
            UserDefaults.standard.set(autoLiveActivity, forKey: "autoLiveActivity")
            if !autoLiveActivity && activityWasAutomatic { endActivity() }
            if autoLiveActivity {
                manuallyEndedActivity = false
                attemptedAutoActivity = false
                startAutomaticActivityIfPossible()
            }
        }
    }
    var widgetContainerAvailable: Bool { presentation.groupIsAvailable }
    #endif
    @Published var scenario: SimulationScenario

    private let presentation = TelemetryPresentation()
    private let launchScenario: SimulationScenario?
    private var session: Task<Void, Never>?
    private var transport: (any OBDTransport)?
    private var runID = UUID()
    private var monitor = OverheatMonitor()
    private var warmup = WarmupHistory()
    private var started = false
    private var hasBeenActive = false
    private var sceneIsActive = false
    private var backgroundSince: ContinuousClock.Instant?
    private var manuallyStopped = false
    private var attemptedAutoActivity = false
    private var manuallyEndedActivity = false
    private var activityWasAutomatic = false
    private var allowsNotifications = false
    private static let thresholdsKey = "thermalThresholds"

    init() {
        let args = ProcessInfo.processInfo.arguments
        let testScenario = args.firstIndex(of: "--simulation-scenario").flatMap { index in
            args.indices.contains(index + 1) ? SimulationScenario(rawValue: args[index + 1]) : nil
        }
        launchScenario = testScenario
        scenario = testScenario ?? .warmup
        let saved = UserDefaults.standard.data(forKey: Self.thresholdsKey)
            .flatMap { try? JSONDecoder().decode(ThermalThresholds.self, from: $0) }
        thresholds = saved ?? .standard
        monitor.apply(thresholds)
    }

    func sceneChanged(active: Bool, background: Bool) {
        let enteringForeground = active && (!hasBeenActive || backgroundSince != nil)
        if background, backgroundSince == nil { backgroundSince = .now }
        if active {
            hasBeenActive = true
            backgroundSince = nil
        }
        sceneIsActive = active
        presentation.isForeground = active
        ble.allowsUnfilteredScan = active

        if !started {
            guard active else { return }
            started = true
            presentation.cleanUpPreviousRun()
            source = VehicleSessionPolicy.initialSource(hasSavedAdapter: ble.selectedID != nil,
                                                        launchesSimulator: launchScenario != nil)
            if source == .simulator || autoConnect { start() }
            else { showManualConnection() }
            Task { await refreshNotificationPermission() }
            return
        }

        guard enteringForeground else { return }
        refreshActivityState()
        if source == .vehicle, autoConnect, !manuallyStopped,
           !isRunning || (phase == .streaming && coolant?.isFresh(at: Date()) != true) {
            start(preservingHistory: true)
        } else {
            startAutomaticActivityIfPossible()
        }
    }

    func switchSource(to newSource: DataSource) {
        guard source != newSource else { return }
        stopSession()
        manuallyStopped = false
        source = newSource
        resetHistory()
        if newSource == .simulator || (autoConnect && ble.selectedID != nil && sceneIsActive) { start() }
        else { showManualConnection() }
    }

    private func showManualConnection() {
        phase = ble.selectedID == nil ? .awaitingAdapter : .idle
        status = "Выберите адаптер или подключитесь вручную"
    }

    func setThreshold(_ limit: ThermalThresholds.Limit, to value: Int) {
        guard let adjusted = thresholds.setting(limit, to: value) else { return }
        applyThresholds(adjusted)
    }

    func resetThresholds() { applyThresholds(.standard) }

    private func applyThresholds(_ values: ThermalThresholds) {
        thresholds = values
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: Self.thresholdsKey)
        monitor.apply(values)
        level = monitor.update(coolant, at: Date())
    }

    func setScenario(_ scenario: SimulationScenario) {
        self.scenario = scenario
        if source == .simulator && !manuallyStopped { start() }
    }

    func selectDevice(_ id: UUID) {
        guard ble.select(id) else { return }
        start()
    }

    func discoverAdapters() {
        guard source == .vehicle, sceneIsActive, !isRunning else { return }
        if ble.isClosed { replaceBLE() }
        ble.discover()
    }

    func start(preservingHistory: Bool = false) {
        let previousLevel = level
        stopSession(resetBLE: false)
        manuallyStopped = false
        attemptedAutoActivity = false
        if !preservingHistory { manuallyEndedActivity = false }
        guard source == .simulator || ble.selectedID != nil else {
            phase = .awaitingAdapter
            status = "Сначала выберите BLE-адаптер"
            return
        }
        if preservingHistory {
            warmup.interrupt()
            level = previousLevel
        } else {
            resetHistory()
        }
        // Reuse the discovery manager on first connection. Replace a closed link before retrying.
        if source == .vehicle && ble.isClosed { replaceBLE() }
        let id = runID
        let currentSource = source
        let currentScenario = scenario
        isRunning = true
        phase = .connecting
        status = "Подключение…"

        session = Task { [weak self] in
            await self?.run(id: id, source: currentSource, scenario: currentScenario)
        }
    }

    func stop() {
        manuallyStopped = true
        stopSession()
    }

    private func replaceBLE() {
        let replacement = BLETransport()
        replacement.allowsUnfilteredScan = sceneIsActive
        ble = replacement
    }

    private func stopSession(resetBLE: Bool = true) {
        runID = UUID()
        session?.cancel()
        session = nil
        transport?.disconnect()
        transport = nil
        if resetBLE {
            ble.disconnect()
            replaceBLE()
        }
        isRunning = false
        phase = .stopped
        status = "Измерение остановлено"
        coolant = nil
        supplementary = nil
        monitor = OverheatMonitor()
        monitor.apply(thresholds)
        level = .normal
        presentation.clearWidget()
        endActivity()
    }

    private func resetHistory() {
        warmup = WarmupHistory()
        history = []
    }

    func toggleActivity() {
        attemptedAutoActivity = true
        if presentation.hasActivity {
            manuallyEndedActivity = true
            endActivity()
            return
        }
        startActivity(automatically: false)
    }

    private func startAutomaticActivityIfPossible() {
        #if !CARGAUGE_BASIC
        guard autoLiveActivity, !attemptedAutoActivity, !manuallyEndedActivity, sceneIsActive,
              !presentation.hasActivity, coolant?.isFresh(at: Date()) == true else { return }
        attemptedAutoActivity = true
        startActivity(automatically: true)
        #endif
    }

    private func startActivity(automatically: Bool) {
        guard sceneIsActive, let coolant else { return }
        do {
            try presentation.startActivity(coolant: coolant, source: source, level: level) { [weak self] error in
                guard let self else { return }
                self.refreshActivityState()
                self.presentationMessage = error?.localizedDescription
                if error != nil {
                    self.activityWasAutomatic = false
                    // A queued start may expire while the app is switching scenes.
                    if !self.sceneIsActive { self.attemptedAutoActivity = false }
                }
            }
            activityWasAutomatic = automatically
            activityIsRunning = presentation.hasActivity
            presentationMessage = nil
        } catch {
            presentationMessage = error.localizedDescription
        }
    }

    func refreshActivityState() {
        let running = presentation.hasActivity
        if activityIsRunning != running { activityIsRunning = running }
    }

    func requestWarningNotifications() async {
        do {
            allowsNotifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            presentationMessage = allowsNotifications ? "Уведомления разрешены" : "Уведомления выключены в настройках iPhone"
        } catch {
            presentationMessage = error.localizedDescription
        }
    }

    private func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        allowsNotifications = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func endActivity() {
        presentation.endActivity()
        activityIsRunning = false
        activityWasAutomatic = false
    }

    private func run(id: UUID, source: DataSource, scenario: SimulationScenario) async {
        var failures = 0
        var simulatedBreak = scenario == .reconnect
        while !Task.isCancelled && id == runID {
            let simulatedScenario: SimulationScenario = scenario == .reconnect
                ? (simulatedBreak ? .disconnect : .warmup) : scenario
            let link: any OBDTransport = source == .vehicle ? ble : SimulatedTransport(scenario: simulatedScenario)
            transport = link
            let client = ELM327Client(transport: link)
            var engine = EngineIdleMonitor()
            var healthySamples = 0
            do {
                phase = .connecting
                status = "Подключение…"
                try await link.connect()
                try await client.initialize()
                while !Task.isCancelled && id == runID {
                    if source == .vehicle, backgroundBudgetExpired {
                        park("Измерения в фоне приостановлены")
                        return
                    }
                    let reading = try await client.readCoolant()
                    guard !Task.isCancelled, id == runID else { return }
                    phase = .streaming
                    status = source == .simulator ? "Симулятор подключён" : "ECU подключён"
                    accept(reading, source: source)
                    startAutomaticActivityIfPossible()
                    await presentation.publish(coolant: reading, source: source, level: level)
                    try Task.checkCancellation()
                    guard id == runID else { return }
                    refreshActivityState()
                    let snapshot = try await client.readSupplementary(source: source, coolant: reading)
                    guard !Task.isCancelled, id == runID else { return }
                    supplementary = snapshot
                    if failures > 0 {
                        healthySamples += 1
                        if healthySamples >= VehicleSessionPolicy.healthySamplesBeforeReset { failures = 0 }
                    }
                    if (source == .vehicle || scenario == .engineOff),
                       engine.shouldPark(after: snapshot.rpm, at: Date()) {
                        park("Обороты двигателя упали до нуля")
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                guard !Task.isCancelled, id == runID else { return }
                link.disconnect()
                transport = nil
                coolant = nil
                supplementary = nil
                warmup.interrupt()
                failures += 1
                let shouldRetry = source == .vehicle ? autoConnect : simulatedBreak
                guard shouldRetry,
                      let seconds = VehicleSessionPolicy.retryDelay(afterConsecutiveFailures: failures,
                                                                  inForeground: sceneIsActive) else {
                    finishFailure(error)
                    return
                }
                simulatedBreak = false
                phase = .retrying
                status = "\(error.localizedDescription). Повтор через \(Int(seconds)) с"
                await presentation.markActivityStale()
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled, id == runID else { return }
                if !sceneIsActive || (source == .vehicle && !autoConnect) {
                    finishFailure(error)
                    return
                }
                if source == .vehicle { replaceBLE() }
            }
        }
    }

    private var backgroundBudgetExpired: Bool {
        backgroundSince.map { $0.duration(to: .now) >= .seconds(VehicleSessionPolicy.maximumBackgroundTime) } ?? false
    }

    private func park(_ message: String) {
        stopSession()
        phase = .parked
        status = message
    }

    private func finishFailure(_ error: Error) {
        presentation.clearWidget()
        endActivity()
        phase = .failed
        status = "Нет данных. \(error.localizedDescription)"
        isRunning = false
    }

    private func accept(_ reading: Reading, source: DataSource) {
        coolant = reading
        warmup.append(reading)
        history = warmup.points
        let oldLevel = monitor.level
        level = monitor.update(reading, at: Date())
        if source == .vehicle, allowsNotifications, level != .normal,
           (oldLevel == .normal || (oldLevel == .warning && level == .critical)) {
            let content = UNMutableNotificationContent()
            content.title = level == .critical ? "Критическая температура ОЖ" : "Высокая температура ОЖ"
            content.body = "\(Int(reading.value)) °C по данным ECU"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            Task {
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
}

#if DEBUG
extension DashboardModel {
    static func preview(at now: Date, source: DataSource = .simulator, finalTemperature: Int = 91) -> DashboardModel {
        let model = DashboardModel()
        model.source = source
        model.thresholds = .standard
        model.monitor.apply(.standard)
        model.phase = .streaming
        model.isRunning = true
        model.status = source == .simulator ? "Симулятор подключён" : "ECU подключён"
        for index in 0...23 {
            if (8...11).contains(index) { continue }
            let progress = Double(index) / 23
            let temperature = 34 + (Double(finalTemperature) - 34) * (1 - pow(1 - progress, 2))
            model.accept(Reading(temperature.rounded(), at: now.addingTimeInterval(Double(index - 23) * 4)), source: source)
        }
        if let coolant = model.coolant {
            model.supplementary = TelemetrySnapshot(source: source, coolant: coolant, rpm: Reading(846, at: now),
                                                   voltage: Reading(14.2, at: now), voltageSource: .ecu)
        }
        return model
    }
}
#endif
