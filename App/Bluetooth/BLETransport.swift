import CarGaugeCore
import Combine
@preconcurrency import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int

    var hasName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var matchesVgateName: Bool {
        BLEAdvertisementName.isLikelyOBD(name)
    }
}

enum BLEScanState: Equatable {
    case idle
    case scanning
    case finished
    case poweredOff
    case unauthorized
    case unavailable
}

/// Structured transport diagnostics. Associated strings contain technical details,
/// whereas `diagnostic` is intended for short user-facing status text.
enum BLEDiagnostic: Equatable {
    case noSelection
    case selected(UUID)
    case discovering
    case discoveryFinished(count: Int)
    case discoveryCancelled
    case searchingForSelection(UUID)
    case connecting(UUID)
    case ready(service: String)
    case poweredOff
    case unauthorized
    case unavailable
    case resetting
    case timeout
    case disconnected
    case cancelled
    case unsupportedProfile(services: [String])
    case failure(String)
}

/// Candidate profiles are checked against discovered characteristic properties before use.
@MainActor final class BLETransport: NSObject, ObservableObject, OBDTransport {
    private struct Profile {
        let service: CBUUID
        let notify: CBUUID
        let write: CBUUID

        init(_ service: String, _ notify: String, _ write: String) {
            self.service = CBUUID(string: service)
            self.notify = CBUUID(string: notify)
            self.write = CBUUID(string: write)
        }
    }

    private static let profiles = [Profile("18F0", "2AF0", "2AF1"), Profile("FFF0", "FFF1", "FFF2"), Profile("FFE0", "FFE1", "FFE1")]
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var scanState: BLEScanState = .idle
    @Published private(set) var diagnostic = "Адаптер не выбран"
    @Published private(set) var diagnosticDetail: BLEDiagnostic = .noSelection
    @Published private(set) var selectedID: UUID?
    @Published private(set) var selectedName: String?

    /// Enables unfiltered scans for a selected UUID only in the foreground.
    /// Discovery itself is always unfiltered and must be started by the user.
    var allowsUnfilteredScan = false {
        didSet {
            guard oldValue != allowsUnfilteredScan, scanningForSelection else { return }
            manager?.stopScan()
            startScanIfPossible()
        }
    }

    private var manager: CBCentralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var advertisementNames: [UUID: String] = [:]
    private var discoveryRSSI: [UUID: Int] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var profile: Profile?
    private var remainingProfiles: [(profile: Profile, service: CBService)] = []
    private var serviceUUIDs: [String] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var responseWaiter: CheckedContinuation<String, Error>?
    private var operationID: UUID?
    private var deadline: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var retrievalDeadline: Task<Void, Never>?
    private var frame = ELMCommandFrame()
    private var pendingWrite: Data?
    private var waitingForWriteAck = false
    private var discovering = false
    private var extendedDiscovery = false
    private var scanningForSelection = false
    private var ready = false
    private var closed = false
    var isClosed: Bool { closed }
    var permitsAutomaticRetry: Bool {
        switch diagnosticDetail {
        case .unauthorized, .poweredOff, .unavailable, .unsupportedProfile: false
        default: true
        }
    }

    init(targetID: UUID? = nil) {
        selectedID = targetID
        super.init()
        if let targetID {
            setDiagnostic(.selected(targetID), "Сохранён выбранный адаптер")
        }
    }

    private func setDiagnostic(_ detail: BLEDiagnostic, _ message: String) {
        diagnosticDetail = detail
        diagnostic = message
    }

    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard !closed, connectWaiter == nil, !ready,
              discoveredPeripherals[id] != nil,
              let device = devices.first(where: { $0.id == id }) else { return false }
        selectedID = id
        selectedName = device.hasName ? device.name : nil
        finishDiscovery(state: .finished)
        setDiagnostic(.selected(id), "Адаптер выбран")
        return true
    }

    func discover(extended: Bool = false) {
        guard !closed, connectWaiter == nil, !ready else { return }
        if discovering { finishDiscovery(state: .idle) }
        devices = []
        discoveredPeripherals.removeAll()
        advertisementNames.removeAll()
        discoveryRSSI.removeAll()
        extendedDiscovery = extended
        discovering = true
        scanState = .scanning
        setDiagnostic(.discovering, "Поиск BLE-устройств…")
        ensureManager()
        scanDeadline?.cancel()
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.discovering, !Task.isCancelled else { return }
            self.finishDiscovery(state: .finished)
            self.setDiagnostic(.discoveryFinished(count: self.devices.count),
                               self.devices.isEmpty ? "Устройства не найдены. Проверьте питание и BLE." : "Выберите свой адаптер")
        }
        updateDiscoveryForManagerState()
    }

    /// Call when the discovery screen is dismissed. It never stops a selection scan.
    func cancelDiscovery() {
        guard discovering else { return }
        finishDiscovery(state: .idle)
        setDiagnostic(.discoveryCancelled, "Поиск остановлен")
    }

    private func finishDiscovery(state: BLEScanState) {
        guard discovering else { return }
        discovering = false
        scanDeadline?.cancel()
        scanDeadline = nil
        if !scanningForSelection { manager?.stopScan() }
        for device in discoveredPeripherals.values where device !== peripheral {
            device.delegate = nil
        }
        scanState = state
    }

    private func updateDiscoveredDevice(_ device: CBPeripheral) {
        guard discovering, discoveredPeripherals[device.identifier] === device,
              let rssi = discoveryRSSI[device.identifier] else { return }
        let name = BLEAdvertisementName.preferred(
            advertised: nil,
            peripheral: device.name,
            previousAdvertisement: advertisementNames[device.identifier]
        )
        let item = BLEDevice(id: device.identifier, name: name, rssi: rssi)
        guard extendedDiscovery || item.hasName else { return }
        if let index = devices.firstIndex(where: { $0.id == device.identifier }) {
            guard devices[index].name != item.name || devices[index].rssi != item.rssi else { return }
            devices[index] = item
        } else {
            devices.append(item)
        }
        devices.sort {
            $0.matchesVgateName == $1.matchesVgateName ? $0.rssi > $1.rssi : $0.matchesVgateName
        }
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard !closed, selectedID != nil else { throw OBDError.adapter("Сначала выберите адаптер") }
        guard connectWaiter == nil && !ready else { throw OBDError.busy }
        finishDiscovery(state: .finished)
        ensureManager()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operationID = id
                connectWaiter = continuation
                armDeadline(seconds: 20, operation: id)
                beginConnectionIfPossible()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(id) }
        }
    }

    func disconnect() { fail(OBDError.disconnected, detail: .disconnected) }

    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let allowed = ELM327Client.initializationCommands + OBDPID.allCases.map(\.rawValue) + ["ATRV"]
        guard allowed.contains(command) else { throw OBDError.unsupported }
        guard ready, !closed, peripheral?.state == .connected else { throw OBDError.disconnected }
        guard responseWaiter == nil else { throw OBDError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operationID = id
                responseWaiter = continuation
                frame = ELMCommandFrame()
                pendingWrite = Data((command + "\r").utf8)
                armDeadline(seconds: timeout, operation: id)
                flushWrite()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOperation(id) }
        }
    }

    private func cancelOperation(_ id: UUID) {
        guard operationID == id else { return }
        fail(CancellationError(), detail: .cancelled)
    }

    private func ensureManager() {
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    private func startScanIfPossible() {
        guard let manager, manager.state == .poweredOn, discovering || scanningForSelection else { return }
        let services: [CBUUID]? = discovering || allowsUnfilteredScan ? nil : Self.profiles.map(\.service)
        manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func updateDiscoveryForManagerState() {
        guard discovering, let manager else { return }
        switch manager.state {
        case .poweredOn:
            scanState = .scanning
            startScanIfPossible()
        case .unauthorized:
            finishDiscovery(state: .unauthorized)
            setDiagnostic(.unauthorized, "Разрешите Bluetooth в настройках iPhone")
        case .poweredOff:
            finishDiscovery(state: .poweredOff)
            setDiagnostic(.poweredOff, "Bluetooth выключен")
        case .unsupported:
            finishDiscovery(state: .unavailable)
            setDiagnostic(.unavailable, "BLE недоступен")
        case .resetting:
            finishDiscovery(state: .unavailable)
            setDiagnostic(.resetting, "Bluetooth перезапускается. Повторите поиск")
        case .unknown:
            break
        @unknown default:
            finishDiscovery(state: .unavailable)
            setDiagnostic(.unavailable, "BLE недоступен")
        }
    }

    private func beginConnectionIfPossible() {
        guard connectWaiter != nil, peripheral == nil, !scanningForSelection,
              let manager, let selectedID else { return }
        switch manager.state {
        case .poweredOn:
            let retrieved = manager.retrievePeripherals(withIdentifiers: [selectedID])
            let connected = manager.retrieveConnectedPeripherals(withServices: Self.profiles.map(\.service))
            if let device = connected.first(where: { $0.identifier == selectedID })
                ?? retrieved.first(where: { $0.identifier == selectedID })
                ?? discoveredPeripherals[selectedID] {
                attach(device, retrieved: true)
            } else {
                scanForSelection()
            }
        case .unauthorized:
            fail(OBDError.adapter("Разрешите Bluetooth в настройках iPhone"), detail: .unauthorized)
        case .poweredOff:
            fail(OBDError.adapter("Bluetooth выключен"), detail: .poweredOff)
        case .unsupported:
            fail(OBDError.adapter("BLE недоступен"), detail: .unavailable)
        case .resetting:
            fail(OBDError.adapter("Bluetooth перезапускается. Повторите подключение"), detail: .resetting)
        case .unknown:
            break
        @unknown default:
            fail(OBDError.adapter("BLE недоступен"), detail: .unavailable)
        }
    }

    private func scanForSelection() {
        guard connectWaiter != nil, !closed, let selectedID else { return }
        retrievalDeadline?.cancel()
        retrievalDeadline = nil
        scanningForSelection = true
        setDiagnostic(.searchingForSelection(selectedID), "Поиск выбранного адаптера…")
        startScanIfPossible()
    }

    private func attach(_ device: CBPeripheral, retrieved: Bool) {
        guard !closed, connectWaiter != nil, peripheral == nil,
              device.identifier == selectedID, let manager else { return }
        manager.stopScan()
        scanningForSelection = false
        peripheral = device
        device.delegate = self
        setDiagnostic(.connecting(device.identifier), "Подключение к выбранному устройству…")
        if device.state == .connected {
            device.discoverServices(nil)
        } else {
            manager.connect(device, options: nil)
        }
        if retrieved, let id = operationID {
            retrievalDeadline?.cancel()
            retrievalDeadline = Task { [weak self, weak device] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let device, !Task.isCancelled, self.operationID == id,
                      self.connectWaiter != nil, self.peripheral === device else { return }
                self.abandonRetrievedDevice(device)
            }
        }
    }

    private func abandonRetrievedDevice(_ device: CBPeripheral) {
        guard peripheral === device, connectWaiter != nil else { return }
        retrievalDeadline?.cancel()
        retrievalDeadline = nil
        device.delegate = nil
        peripheral = nil
        discoveredPeripherals.removeValue(forKey: device.identifier)
        manager?.cancelPeripheralConnection(device)
        // Late callbacks from the cached connection must not affect the scanned connection.
        manager?.delegate = nil
        manager = nil
        scanForSelection()
        ensureManager()
        startScanIfPossible()
    }

    private func armDeadline(seconds: TimeInterval, operation id: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled, self.operationID == id else { return }
            self.fail(OBDError.timeout, detail: .timeout)
        }
    }

    private func flushWrite() {
        guard let peripheral, let characteristic = writeCharacteristic, let data = pendingWrite else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else {
            fail(OBDError.adapter("Слишком маленький BLE MTU")); return
        }
        pendingWrite = nil
        waitingForWriteAck = type == .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func completeExchangeIfReady() {
        guard !waitingForWriteAck, frame.response != nil, let id = operationID else { return }
        deadline?.cancel()
        // Give queued trailing notifications a chance to arrive before the next write.
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard let self, !Task.isCancelled, self.operationID == id,
                  let response = self.frame.response, let waiter = self.responseWaiter else { return }
            self.deadline = nil
            self.operationID = nil
            self.frame = ELMCommandFrame()
            self.responseWaiter = nil
            waiter.resume(returning: response)
        }
    }

    private func fail(_ error: Error, detail: BLEDiagnostic? = nil) {
        guard !closed else { return }
        closed = true
        ready = false
        if discovering { finishDiscovery(state: .finished) }
        scanningForSelection = false
        operationID = nil
        deadline?.cancel()
        scanDeadline?.cancel()
        retrievalDeadline?.cancel()
        deadline = nil
        scanDeadline = nil
        retrievalDeadline = nil
        manager?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            manager?.cancelPeripheralConnection(peripheral)
        }
        manager?.delegate = nil
        discoveredPeripherals.removeAll()
        advertisementNames.removeAll()
        discoveryRSSI.removeAll()
        peripheral = nil
        remainingProfiles.removeAll()
        pendingWrite = nil
        waitingForWriteAck = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        frame = ELMCommandFrame()
        let connection = connectWaiter
        let response = responseWaiter
        connectWaiter = nil
        responseWaiter = nil
        setDiagnostic(detail ?? .failure(error.localizedDescription), error.localizedDescription)
        connection?.resume(throwing: error)
        response?.resume(throwing: error)
    }

    private func discoverNextProfile(on device: CBPeripheral) {
        guard !remainingProfiles.isEmpty else {
            let list = serviceUUIDs.isEmpty ? "нет" : serviceUUIDs.joined(separator: ", ")
            fail(OBDError.adapter("Поддерживаемый GATT-профиль не найден. Сервисы: \(list)"),
                 detail: .unsupportedProfile(services: serviceUUIDs))
            return
        }
        let (candidate, service) = remainingProfiles.removeFirst()
        profile = candidate
        writeCharacteristic = nil
        notifyCharacteristic = nil
        device.discoverCharacteristics(Array(Set([candidate.notify, candidate.write])), for: service)
    }
}

extension BLETransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager, !closed else { return }
        if discovering { updateDiscoveryForManagerState() }
        if central.state != .poweredOn && (ready || peripheral != nil || scanningForSelection) {
            switch central.state {
            case .unauthorized:
                fail(OBDError.adapter("Разрешите Bluetooth в настройках iPhone"), detail: .unauthorized)
            case .poweredOff:
                fail(OBDError.adapter("Bluetooth выключен"), detail: .poweredOff)
            case .resetting:
                fail(OBDError.adapter("Bluetooth перезапускается. Повторите подключение"), detail: .resetting)
            case .unsupported:
                fail(OBDError.adapter("BLE недоступен"), detail: .unavailable)
            case .unknown:
                break
            case .poweredOn:
                break
            @unknown default:
                fail(OBDError.adapter("BLE недоступен"), detail: .unavailable)
            }
            return
        }
        if scanningForSelection {
            if central.state == .poweredOn { startScanIfPossible() }
        } else {
            beginConnectionIfPossible()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, !closed else { return }
        if scanningForSelection, connectWaiter != nil, device.identifier == selectedID {
            attach(device, retrieved: false)
            return
        }
        guard discovering else { return }
        let id = device.identifier
        if let oldDevice = discoveredPeripherals[id], oldDevice !== device {
            oldDevice.delegate = nil
        }
        discoveredPeripherals[id] = device
        discoveryRSSI[id] = RSSI.intValue
        if let name = BLEAdvertisementName.clean(advertisementData[CBAdvertisementDataLocalNameKey] as? String) {
            advertisementNames[id] = name
        }
        device.delegate = self
        updateDiscoveredDevice(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard central === manager, device === peripheral, !closed, connectWaiter != nil else { return }
        device.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard central === manager, device === peripheral, !closed else { return }
        if retrievalDeadline != nil && connectWaiter != nil {
            abandonRetrievedDevice(device)
        } else {
            fail(error ?? OBDError.disconnected)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard central === manager, device === peripheral, !closed else { return }
        if retrievalDeadline != nil && connectWaiter != nil {
            abandonRetrievedDevice(device)
        } else {
            fail(error ?? OBDError.disconnected, detail: error == nil ? .disconnected : nil)
        }
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
    func peripheralDidUpdateName(_ device: CBPeripheral) {
        guard !closed, discovering, discoveredPeripherals[device.identifier] === device else { return }
        updateDiscoveredDevice(device)
    }

    func peripheral(_ device: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard device === peripheral, !closed, !invalidatedServices.isEmpty else { return }
        if let profile, invalidatedServices.allSatisfy({ $0.uuid != profile.service }) { return }
        // The previous characteristic references are invalid. Reinitialize ELM on a new transport.
        fail(OBDError.adapter("BLE-сервисы адаптера изменились"))
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral, !closed, connectWaiter != nil else { return }
        if let error { fail(error); return }
        serviceUUIDs = Array((device.services ?? []).map { $0.uuid.uuidString }.sorted().prefix(8))
        remainingProfiles = Self.profiles.compactMap { candidate in
            guard let service = device.services?.first(where: { $0.uuid == candidate.service }) else { return nil }
            return (profile: candidate, service: service)
        }
        discoverNextProfile(on: device)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral, !closed, connectWaiter != nil,
              let profile, service.uuid == profile.service else { return }
        guard error == nil, let tx = service.characteristics?.first(where: { $0.uuid == profile.write }),
              let rx = service.characteristics?.first(where: { $0.uuid == profile.notify }),
              !tx.properties.intersection([.write, .writeWithoutResponse]).isEmpty,
              !rx.properties.intersection([.notify, .indicate]).isEmpty else {
            discoverNextProfile(on: device)
            return
        }
        writeCharacteristic = tx
        notifyCharacteristic = rx
        device.setNotifyValue(true, for: rx)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic === notifyCharacteristic, !closed else { return }
        guard error == nil, characteristic.isNotifying else {
            if ready { fail(error ?? OBDError.disconnected) }
            else if connectWaiter != nil { discoverNextProfile(on: device) }
            return
        }
        guard !ready, let continuation = connectWaiter else { return }
        ready = true
        retrievalDeadline?.cancel()
        retrievalDeadline = nil
        deadline?.cancel()
        deadline = nil
        operationID = nil
        let service = profile?.service.uuidString ?? ""
        setDiagnostic(.ready(service: service), "BLE готов")
        connectWaiter = nil
        continuation.resume()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic === notifyCharacteristic, !closed else { return }
        if let error { fail(error); return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        if (responseWaiter == nil || pendingWrite != nil) && ELMPromptBuffer.isPadding(data) { return }
        guard responseWaiter != nil, pendingWrite == nil else {
            fail(OBDError.malformedResponse)
            return
        }
        do {
            if try frame.append(data) { completeExchangeIfReady() }
        } catch { fail(error) }
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic === writeCharacteristic, !closed, waitingForWriteAck else { return }
        if let error { fail(error); return }
        waitingForWriteAck = false
        completeExchangeIfReady()
    }

    func peripheralIsReady(toSendWriteWithoutResponse device: CBPeripheral) {
        guard device === peripheral, !closed else { return }
        flushWrite()
    }
}
