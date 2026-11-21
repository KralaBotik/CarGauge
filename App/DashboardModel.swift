import CarGaugeCore
import Combine
import Foundation
import UserNotifications

enum MeasurementPhase {
    case idle, awaitingAdapter, connecting, streaming, retrying, failed, stopped, parked
}

@MainActor final class DashboardModel: ObservableObject {
    @Published private(set) var coolant: Reading?
    @Published private(set) var supplementary: TelemetrySnapshot?
    @Published private(set) var history: [WarmupHistory.Point] = []
    private(set) var tripStartedAt: Date?
    @Published private(set) var level: ThermalLevel = .normal
    @Published private(set) var phase: MeasurementPhase = .idle
    @Published private(set) var thresholds: ThermalThresholds
    @Published private(set) var status = "Ожидание запуска"
    @Published private(set) var isRunning = false
    @Published private(set) var ble: BLETransport
    @Published private(set) var activityIsRunning = false
    @Published var presentationMessage: String?
    @Published var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") == nil
        || UserDefaults.standard.bool(forKey: "autoConnect") {
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
    @Published private(set) var adapterStage = "Ожидание"
    @Published private(set) var configuredName: String?
    @Published private(set) var hasConfiguredAdapter: Bool
    private var pendingAdapterID: UUID?
    private var pendingAdapterName: String?

    var source: DataSource {
        #if DEBUG
        if launchScenario != nil || previewUsesSamples { return .simulator }
        #endif
        return .vehicle
    }

    var connectionTitle: String {
        if phase == .failed {
            switch ble.diagnosticDetail {
            case .poweredOff: return "Bluetooth выключен"
            case .unauthorized: return "Нет доступа к Bluetooth"
            case .unavailable: return "Bluetooth недоступен"
            case .unsupportedProfile: return "Адаптер не поддерживается"
            default: break
            }
        }
        switch phase {
        case .awaitingAdapter: return "Адаптер не настроен"
        case .connecting: return pendingAdapterID == nil ? "Подключение…" : "Проверяем адаптер…"
        case .streaming: return "Подключено"
        case .retrying: return "Восстанавливаем связь…"
        case .failed: return "Нет связи с автомобилем"
        case .stopped: return "Измерения остановлены"
        case .parked: return "Ожидание поездки"
        case .idle: return canRetryConnection ? "Готово к подключению" : "Адаптер не настроен"
        }
    }
    var canRetryConnection: Bool { adapterPreferences.preferredID != nil || source == .simulator }
    var isCheckingSelection: Bool { pendingAdapterID != nil && isRunning }

    private let presentation = TelemetryPresentation()
    private let adapterPreferences: AdapterPreferences
    #if DEBUG
    private let launchScenario: SimulationScenario?
    let discoveryFixture: Bool
    private let waitingFixture: Bool
    private var previewUsesSamples = false
    #endif
    private var session: Task<Void, Never>?
    private var transport: (any OBDTransport)?
    private var runID = UUID()
    private var monitor = OverheatMonitor()
    private var warmup = WarmupHistory()
    private var started = false
    private var sceneIsActive = false
    private var backgroundSince: ContinuousClock.Instant?
    private var manuallyStopped = false
    private var attemptedAutoActivity = false
    private var manuallyEndedActivity = false
    private var activityWasAutomatic = false
    private var allowsNotifications = false
    private static let thresholdsKey = "thermalThresholds"

    init() {
        let preferences = AdapterPreferences(defaults: .standard)
        adapterPreferences = preferences
        configuredName = preferences.name
        hasConfiguredAdapter = preferences.verifiedID != nil
        ble = BLETransport(targetID: preferences.preferredID)
        phase = preferences.preferredID == nil ? .awaitingAdapter : .idle
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        launchScenario = args.firstIndex(of: "--simulation-scenario").flatMap { index in
            args.indices.contains(index + 1) ? SimulationScenario(rawValue: args[index + 1]) : nil
        }
        discoveryFixture = args.contains("--adapter-list-fixture")
        waitingFixture = args.contains("--adapter-waiting-fixture")
        if launchScenario != nil { hasConfiguredAdapter = true }
        #endif
        let saved = UserDefaults.standard.data(forKey: Self.thresholdsKey)
            .flatMap { try? JSONDecoder().decode(ThermalThresholds.self, from: $0) }
        thresholds = saved ?? .standard
        monitor.apply(thresholds)
    }

    func sceneChanged(active: Bool, background: Bool) {
        let becameActive = active && !sceneIsActive
        let returningFromBackground = active && backgroundSince != nil
        if background, backgroundSince == nil { backgroundSince = .now }
        if active { backgroundSince = nil }
        sceneIsActive = active
        presentation.isForeground = active
        ble.allowsUnfilteredScan = active
        if background { ble.cancelDiscovery() }

        if !started {
            guard active else { return }
            started = true
            presentation.cleanUpPreviousRun()
            #if DEBUG
            if waitingFixture {
                hasConfiguredAdapter = true
                phase = .connecting
                isRunning = true
                return
            }
            #endif
            if source == .simulator || (autoConnect && adapterPreferences.preferredID != nil) { start() }
            Task { await refreshNotificationPermission() }
            return
        }

        guard becameActive else { return }
        refreshActivityState()
        let sessionNeedsRecovery = !isRunning || (phase == .streaming && coolant?.isFresh(at: Date()) != true)
        if source == .vehicle, adapterPreferences.preferredID != nil,
           autoConnect, !manuallyStopped, sessionNeedsRecovery, phase != .parked || returningFromBackground {
            start(preservingHistory: true)
        } else {
            startAutomaticActivityIfPossible()
        }
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

    func selectDevice(_ id: UUID) {
        guard !isRunning, ble.select(id) else { return }
        pendingAdapterID = id
        pendingAdapterName = ble.selectedName
        start()
    }

    func discoverAdapters(extended: Bool = false) {
        guard source == .vehicle, sceneIsActive else { return }
        #if DEBUG
        if discoveryFixture { return }
        #endif
        guard !isCheckingSelection else { return }
        if isRunning { stop() }
        if ble.isClosed { replaceBLE() }
        ble.discover(extended: extended)
    }

    func leaveAdapterSetup() {
        ble.cancelDiscovery()
        if isCheckingSelection { stop() }
    }

    func resetAdapter() {
        pendingAdapterID = nil
        pendingAdapterName = nil
        adapterPreferences.clear()
        stop()
        resetHistory()
        hasConfiguredAdapter = false
        configuredName = nil
        phase = .awaitingAdapter
        status = "Выберите новый адаптер"
    }

    func start(preservingHistory: Bool = false) {
        let previousLevel = level
        let previousMonitor = monitor
        let targetID = pendingAdapterID ?? adapterPreferences.preferredID
        stopSession(resetBLE: false)
        manuallyStopped = false
        attemptedAutoActivity = false
        if !preservingHistory { manuallyEndedActivity = false }
        guard source == .simulator || targetID != nil else {
            phase = .awaitingAdapter
            status = "Сначала выберите BLE-адаптер"
            return
        }
        if preservingHistory {
            warmup.interrupt()
            level = previousLevel
            monitor = previousMonitor
        } else {
            resetHistory()
        }
        if source == .vehicle && (ble.isClosed || ble.selectedID != targetID) { replaceBLE() }
        let id = runID
        isRunning = true
        phase = .connecting
        status = "Подключение…"

        session = Task { [weak self] in
            await self?.run(id: id, targetID: targetID)
        }
    }

    func stop() {
        manuallyStopped = true
        pendingAdapterID = nil
        pendingAdapterName = nil
        stopSession()
    }

    private func replaceBLE() {
        let replacement = BLETransport(targetID: pendingAdapterID ?? adapterPreferences.preferredID)
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
        adapterStage = "Ожидание"
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
        tripStartedAt = nil
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
        guard sceneIsActive, coolant != nil else { return }
        let id = runID
        do {
            try presentation.startActivity(source: source) { [weak self] in
                guard let self, self.runID == id, let coolant = self.coolant else { return nil }
                return (coolant, self.level)
            } onDeferredResult: { [weak self] error in
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

    private func run(id: UUID, targetID: UUID?) async {
        var retryBudget = VehicleRetryBudget()
        let source = source
        let startedAt = ContinuousClock.now
        #if DEBUG
        var simulatedBreak = launchScenario == .reconnect
        #endif
        while !Task.isCancelled && id == runID {
            let link: any OBDTransport
            #if DEBUG
            if let scenario = launchScenario {
                let selected: SimulationScenario = scenario == .reconnect
                    ? (simulatedBreak ? .disconnect : .warmup) : scenario
                link = SimulatedTransport(scenario: selected)
            } else {
                link = ble
            }
            #else
            link = ble
            #endif
            transport = link
            let client = ELM327Client(transport: link)
            var engine = EngineIdleMonitor()
            do {
                phase = .connecting
                status = "Подключение…"
                adapterStage = "Связь по Bluetooth"
                try await link.connect()
                guard !Task.isCancelled, id == runID else { return }
                adapterStage = "Проверка ELM327 и ЭБУ"
                try await client.initialize()
                while !Task.isCancelled && id == runID {
                    if source == .vehicle, startedAt.duration(to: .now) >= .seconds(VehicleSessionPolicy.maximumSessionTime) {
                        pauseSession("Длительный сеанс завершён")
                        return
                    }
                    if source == .vehicle, backgroundBudgetExpired {
                        pauseSession("Измерения в фоне приостановлены")
                        return
                    }
                    let reading = try await client.readCoolant()
                    guard !Task.isCancelled, id == runID else { return }
                    if let targetID, source == .vehicle, adapterPreferences.verifiedID != targetID,
                       adapterPreferences.confirm(id: targetID, name: pendingAdapterName ?? ble.selectedName,
                                                  coolant: reading, at: .now) {
                        configuredName = adapterPreferences.name
                        hasConfiguredAdapter = true
                    }
                    pendingAdapterID = nil
                    pendingAdapterName = nil
                    phase = .streaming
                    adapterStage = "ELM327 и ЭБУ отвечают"
                    status = "Получены данные температуры"
                    accept(reading, source: source)
                    startAutomaticActivityIfPossible()
                    presentation.publish(coolant: reading, source: source, level: level)
                    refreshActivityState()
                    let snapshot = try await client.readSupplementary(source: source, coolant: reading)
                    guard !Task.isCancelled, id == runID else { return }
                    supplementary = snapshot
                    retryBudget.didCompleteCycle()
                    if engine.shouldPark(after: snapshot.rpm, at: Date()) {
                        pauseSession("Обороты двигателя упали до нуля", engineStopped: true)
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
                #if DEBUG
                let shouldRetry = source == .simulator ? simulatedBreak : autoConnect && pendingAdapterID == nil && targetID != nil
                if source == .simulator { simulatedBreak = false }
                #else
                let shouldRetry = autoConnect && pendingAdapterID == nil && targetID != nil
                #endif
                guard shouldRetry,
                      let seconds = retryBudget.nextDelay(inForeground: sceneIsActive) else {
                    finishFailure(error)
                    return
                }
                phase = .retrying
                status = "\(error.localizedDescription). Повтор через \(Int(seconds)) с"
                let hadActivity = activityIsRunning
                presentation.markActivityStale()
                refreshActivityState()
                if hadActivity, !activityIsRunning, activityWasAutomatic {
                    attemptedAutoActivity = false
                    activityWasAutomatic = false
                }
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

    private func pauseSession(_ message: String, engineStopped: Bool = false) {
        stopSession()
        if engineStopped { phase = .parked }
        status = message
    }

    private func finishFailure(_ error: Error) {
        pendingAdapterID = nil
        pendingAdapterName = nil
        presentation.clearWidget()
        endActivity()
        phase = .failed
        status = "Нет данных. \(error.localizedDescription)"
        isRunning = false
    }

    private func accept(_ reading: Reading, source: DataSource) {
        coolant = reading
        if tripStartedAt == nil { tripStartedAt = reading.timestamp }
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
    static func preview(at now: Date, finalTemperature: Int = 91) -> DashboardModel {
        let model = DashboardModel()
        model.previewUsesSamples = true
        model.hasConfiguredAdapter = true
        model.thresholds = .standard
        model.monitor.apply(.standard)
        model.phase = .streaming
        model.isRunning = true
        model.status = "Данные предпросмотра"
        for index in 0...23 {
            if (8...11).contains(index) { continue }
            let progress = Double(index) / 23
            let temperature = 34 + (Double(finalTemperature) - 34) * (1 - pow(1 - progress, 2))
            model.accept(Reading(temperature.rounded(), at: now.addingTimeInterval(Double(index - 23) * 4)), source: .simulator)
        }
        if let coolant = model.coolant {
            model.supplementary = TelemetrySnapshot(source: .simulator, coolant: coolant, rpm: Reading(846, at: now),
                                                   voltage: Reading(14.2, at: now), voltageSource: .ecu)
        }
        return model
    }
}
#endif
