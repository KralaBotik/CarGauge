import CarGaugeCore
import Combine
import Foundation
import UserNotifications

@MainActor final class DashboardModel: ObservableObject {
    @Published private(set) var source: DataSource = .simulator
    @Published private(set) var coolant: Reading?
    @Published private(set) var supplementary: TelemetrySnapshot?
    @Published private(set) var history: [Reading] = []
    @Published private(set) var level: ThermalLevel = .normal
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

    init() {
        let args = ProcessInfo.processInfo.arguments
        let testScenario = args.firstIndex(of: "--simulation-scenario").flatMap { index in
            args.indices.contains(index + 1) ? SimulationScenario(rawValue: args[index + 1]) : nil
        }
        launchScenario = testScenario
        scenario = testScenario ?? .warmup
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
        UserDefaults.standard.set(newSource.rawValue, forKey: "lastSource")
        ble = BLETransport()
        if newSource == .simulator || (autoConnect && ble.selectedID != nil) { start() }
        else { status = "Выберите адаптер или подключитесь вручную" }
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
            status = "Сначала выберите BLE-адаптер"
            return
        }
        // BLE instances are single-use. A retry cannot receive callbacks from the previous link.
        if source == .vehicle { ble = BLETransport() }
        let id = runID
        let currentSource = source
        let currentScenario = scenario
        isRunning = true
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
        status = "Измерение остановлено"
        coolant = nil
        supplementary = nil
        warmup = WarmupHistory()
        history = []
        monitor = OverheatMonitor()
        level = .normal
        presentation.clearWidget()
        endActivity()
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

    func refreshActivityState() { activityIsRunning = presentation.hasActivity }

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
                status = "Подключение…"
                try await link.connect()
                try await client.initialize()
                while !Task.isCancelled && id == runID {
                    let reading = try await client.readCoolant()
                    guard !Task.isCancelled, id == runID else { return }
                    backoff.reset()
                    status = source == .simulator ? "Симулятор подключён" : "ECU подключён"
                    accept(reading, source: source)
                    await presentation.publish(coolant: reading, source: source, level: level)
                    try Task.checkCancellation()
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
                presentation.clearWidget()
                if source == .simulator || !autoConnect {
                    endActivity()
                    status = "Нет данных. \(error.localizedDescription)"
                    isRunning = false
                    return
                }
                let seconds = backoff.nextDelay()
                status = "\(error.localizedDescription). Повтор через \(Int(seconds)) с"
                await presentation.markActivityStale()
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled, id == runID else { return }
                if !autoConnect {
                    status = "Автоподключение выключено"
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
        history = warmup.readings
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
