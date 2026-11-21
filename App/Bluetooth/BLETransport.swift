import CarGaugeCore
import Combine
@preconcurrency import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int

    var matchesVgateName: Bool {
        name.localizedCaseInsensitiveContains("vgate") || name.localizedCaseInsensitiveContains("icar")
    }
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
    private static let selectedKey = "selectedBLEPeripheral"
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var diagnostic = "Адаптер не выбран"
    @Published private(set) var selectedID: UUID?
    /// Enable only while the app is in the foreground. Background scans need service filters.
    var allowsUnfilteredScan = false {
        didSet {
            guard oldValue != allowsUnfilteredScan, discovering || scanningForSelection else { return }
            manager?.stopScan()
            startScanIfPossible()
        }
    }

    private var manager: CBCentralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
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
    private var buffer = ELMPromptBuffer()
    private var pendingWrite: Data?
    private var waitingForWriteAck = false
    private var completedResponse: String?
    private var discovering = false
    private var scanningForSelection = false
    private var ready = false
    private var closed = false
    var isClosed: Bool { closed }

    override init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        super.init()
        if selectedID != nil { diagnostic = "Сохранён выбранный адаптер" }
    }

    func select(_ id: UUID) -> Bool {
        guard !closed, connectWaiter == nil, !ready,
              discoveredPeripherals[id] != nil else { return false }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
        diagnostic = "Адаптер выбран: \(id.uuidString)"
        discovering = false
        manager?.stopScan()
        scanDeadline?.cancel()
        scanDeadline = nil
        return true
    }

    func discover() {
        guard !closed, connectWaiter == nil, !ready else { return }
        devices = []
        discoveredPeripherals.removeAll()
        discovering = true
        diagnostic = "Поиск BLE-устройств…"
        ensureManager()
        startScanIfPossible()
        scanDeadline?.cancel()
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.discovering, !Task.isCancelled else { return }
            self.manager?.stopScan()
            self.discovering = false
            self.scanDeadline = nil
            self.diagnostic = self.devices.isEmpty ? "Устройства не найдены. Проверьте питание и BLE." : "Выберите свой адаптер"
        }
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard !closed, selectedID != nil else { throw OBDError.adapter("Сначала выберите адаптер") }
        guard connectWaiter == nil && !ready else { throw OBDError.busy }
        discovering = false
        scanDeadline?.cancel()
        scanDeadline = nil
        manager?.stopScan()
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

    func disconnect() { fail(OBDError.disconnected) }

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
                buffer.reset()
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
        fail(CancellationError())
    }

    private func ensureManager() {
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    private func startScanIfPossible() {
        guard let manager, manager.state == .poweredOn else { return }
        let services: [CBUUID]? = allowsUnfilteredScan ? nil : Self.profiles.map(\.service)
        manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        case .unauthorized: fail(OBDError.adapter("Разрешите Bluetooth в настройках iPhone"))
        case .poweredOff: fail(OBDError.adapter("Bluetooth выключен"))
        case .unsupported: fail(OBDError.adapter("BLE недоступен"))
        case .unknown, .resetting: break
        @unknown default: fail(OBDError.disconnected)
        }
    }

    private func scanForSelection() {
        guard connectWaiter != nil, !closed else { return }
        retrievalDeadline?.cancel()
        retrievalDeadline = nil
        scanningForSelection = true
        diagnostic = "Поиск выбранного адаптера…"
        startScanIfPossible()
    }

    private func attach(_ device: CBPeripheral, retrieved: Bool) {
        guard !closed, connectWaiter != nil, peripheral == nil,
              device.identifier == selectedID, let manager else { return }
        manager.stopScan()
        scanningForSelection = false
        peripheral = device
        device.delegate = self
        diagnostic = "Подключение к выбранному устройству…"
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
            self.fail(OBDError.timeout)
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
        guard !waitingForWriteAck, let response = completedResponse, let waiter = responseWaiter else { return }
        deadline?.cancel()
        deadline = nil
        operationID = nil
        completedResponse = nil
        responseWaiter = nil
        waiter.resume(returning: response)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        ready = false
        discovering = false
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
        peripheral = nil
        remainingProfiles.removeAll()
        pendingWrite = nil
        waitingForWriteAck = false
        completedResponse = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        buffer.reset()
        let connection = connectWaiter
        let response = responseWaiter
        connectWaiter = nil
        responseWaiter = nil
        diagnostic = error.localizedDescription
        connection?.resume(throwing: error)
        response?.resume(throwing: error)
    }

    private func discoverNextProfile(on device: CBPeripheral) {
        guard !remainingProfiles.isEmpty else {
            let list = serviceUUIDs.isEmpty ? "нет" : serviceUUIDs.joined(separator: ", ")
            fail(OBDError.adapter("Поддерживаемый GATT-профиль не найден. Сервисы: \(list)"))
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
        if central.state != .poweredOn && (ready || peripheral != nil) {
            fail(OBDError.disconnected)
            return
        }
        if discovering {
            if central.state == .poweredOn { startScanIfPossible() }
            else if central.state == .unauthorized { diagnostic = "Разрешите Bluetooth в настройках iPhone" }
            else if central.state == .poweredOff { diagnostic = "Bluetooth выключен" }
        }
        if scanningForSelection {
            if central.state == .poweredOn { startScanIfPossible() }
            else if central.state == .unauthorized { fail(OBDError.adapter("Разрешите Bluetooth в настройках iPhone")) }
            else if central.state == .poweredOff { fail(OBDError.adapter("Bluetooth выключен")) }
            else if central.state == .unsupported { fail(OBDError.adapter("BLE недоступен")) }
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
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? device.name ?? "BLE-устройство"
        if discoveredPeripherals[device.identifier] == nil {
            discoveredPeripherals[device.identifier] = device
            devices.append(BLEDevice(id: device.identifier, name: name, rssi: RSSI.intValue))
            devices.sort {
                $0.matchesVgateName == $1.matchesVgateName ? $0.rssi > $1.rssi : $0.matchesVgateName
            }
        }
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
            fail(error ?? OBDError.disconnected)
        }
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
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
        diagnostic = "BLE готов: \(profile?.service.uuidString ?? "")"
        connectWaiter = nil
        continuation.resume()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic === notifyCharacteristic, !closed else { return }
        if let error { fail(error); return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        guard responseWaiter != nil, pendingWrite == nil, completedResponse == nil else {
            fail(OBDError.malformedResponse)
            return
        }
        do {
            let frames = try buffer.append(data)
            guard !frames.isEmpty else { return }
            guard frames.count == 1, !buffer.hasPartialPayload else {
                fail(OBDError.malformedResponse)
                return
            }
            completedResponse = frames[0]
            completeExchangeIfReady()
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
