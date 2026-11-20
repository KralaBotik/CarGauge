import CarGaugeCore
import Combine
import Foundation
import UserNotifications

enum MeasurementPhase {
    case idle, awaitingAdapter, connecting, streaming, retrying, failed, stopped
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
    @Published var autoConnect = UserDefaults.standard.bool(forKey: "autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }
    @Published var scenario: SimulationScenario

    private let presentation = TelemetryPresentation()
    private let launchScenario: SimulationScenario?
    private var session: Task<Void, Never>?
    private var transport: (any OBDTransport)?
    private var runID = UUID()
    private var monitor = OverheatMonitor()
    private var warmup = WarmupHistory()
    private var started = false
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

    func launch() {
        guard !started else { return }
        started = true
        presentation.cleanUpPreviousRun()
        if launchScenario == nil, autoConnect, ble.selectedID != nil,
           UserDefaults.standard.string(forKey: "lastSource") == DataSource.vehicle.rawValue {
            switchSource(to: .vehicle)
        } else {
            start()
        }
        Task { await refreshNotificationPermission() }
    }

    func switchSource(to newSource: DataSource) {
        guard source != newSource else { return }
        stop()
        source = newSource
        resetHistory()
        UserDefaults.standard.set(newSource.rawValue, forKey: "lastSource")
        ble = BLETransport()
        if newSource == .simulator || (autoConnect && ble.selectedID != nil) { start() }
        else {
            phase = ble.selectedID == nil ? .awaitingAdapter : .idle
            status = "Выберите адаптер или подключитесь вручную"
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

    func setScenario(_ scenario: SimulationScenario) {
        self.scenario = scenario
        if source == .simulator && isRunning { start() }
    }

    func selectDevice(_ id: UUID) {
        ble.select(id)
        start()
    }

    func start() {
        stop(resetBLE: false)
        guard source == .simulator || ble.selectedID != nil else {
            phase = .awaitingAdapter
            status = "Сначала выберите BLE-адаптер"
            return
        }
        resetHistory()
        // Reuse the discovery manager on first connection. Replace a closed link before retrying.
        if source == .vehicle && ble.isClosed { ble = BLETransport() }
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

    func stop(resetBLE: Bool = true) {
        runID = UUID()
        session?.cancel()
        session = nil
        transport?.disconnect()
        transport = nil
        if resetBLE {
            ble.disconnect()
            ble = BLETransport()
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
        if presentation.hasActivity { endActivity(); return }
        guard let coolant else { return }
        do {
            try presentation.startActivity(coolant: coolant, source: source, level: level)
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
    }

    private func run(id: UUID, source: DataSource, scenario: SimulationScenario) async {
        var backoff = ReconnectBackoff()
        while !Task.isCancelled && id == runID {
            let link: any OBDTransport = source == .vehicle ? ble : SimulatedTransport(scenario: scenario)
            transport = link
            let client = ELM327Client(transport: link)
            do {
                phase = .connecting
                status = "Подключение…"
                try await link.connect()
                try await client.initialize()
                while !Task.isCancelled && id == runID {
                    let reading = try await client.readCoolant()
                    guard !Task.isCancelled, id == runID else { return }
                    backoff.reset()
                    phase = .streaming
                    status = source == .simulator ? "Симулятор подключён" : "ECU подключён"
                    accept(reading, source: source)
                    await presentation.publish(coolant: reading, source: source, level: level)
                    try Task.checkCancellation()
                    refreshActivityState()
                    let snapshot = try await client.readSupplementary(source: source, coolant: reading)
                    guard !Task.isCancelled, id == runID else { return }
                    supplementary = snapshot
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                link.disconnect()
                guard !Task.isCancelled, id == runID else { return }
                transport = nil
                coolant = nil
                supplementary = nil
                warmup.interrupt()
                presentation.clearWidget()
                if source == .simulator || !autoConnect {
                    endActivity()
                    phase = .failed
                    status = "Нет данных. \(error.localizedDescription)"
                    isRunning = false
                    return
                }
                let seconds = backoff.nextDelay()
                phase = .retrying
                status = "\(error.localizedDescription). Повтор через \(Int(seconds)) с"
                await presentation.markActivityStale()
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled, id == runID else { return }
                if !autoConnect {
                    status = "Автоподключение выключено"
                    phase = .stopped
                    endActivity()
                    isRunning = false
                    return
                }
                ble = BLETransport()
            }
        }
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
