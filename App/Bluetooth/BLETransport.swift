import CarGaugeCore
import Combine
@preconcurrency import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// The profiles are candidates, verified against discovered properties before use.
/// The user's particular iCar Pro firmware still needs hardware validation.
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
    private var manager: CBCentralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var profile: Profile?
    private var remainingProfiles: [(profile: Profile, service: CBService)] = []
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var responseWaiter: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var buffer = ELMPromptBuffer()
    private var pendingWrite: Data?
    private var waitingForWriteAck = false
    private var completedResponse: String?
    private var discovering = false
    private var ready = false
    private var closed = false
    var isClosed: Bool { closed }

    override init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        super.init()
        if selectedID != nil { diagnostic = "Сохранён выбранный адаптер" }
    }

    func select(_ id: UUID) {
        guard connectWaiter == nil && !ready else { return }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
        diagnostic = "Адаптер выбран"
        discovering = false
        manager?.stopScan()
        scanDeadline?.cancel()
    }

    func discover() {
        guard !closed, connectWaiter == nil, !ready else { return }
        devices = []
        discoveredPeripherals.removeAll()
        discovering = true
        diagnostic = "Поиск BLE-адаптеров…"
        ensureManager()
        startScanIfPossible()
        scanDeadline?.cancel()
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self else { return }
            self.manager?.stopScan()
            self.discovering = false
            self.diagnostic = self.devices.isEmpty ? "Адаптеры не найдены. Проверьте питание и BLE." : "Выберите свой адаптер"
        }
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard !closed, selectedID != nil else { throw OBDError.adapter("Сначала выберите адаптер") }
        guard connectWaiter == nil && !ready else { throw OBDError.busy }
        discovering = false
        scanDeadline?.cancel()
        ensureManager()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectWaiter = continuation
                armDeadline(seconds: 20)
                beginConnectionIfPossible()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    func disconnect() { fail(OBDError.disconnected) }

    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let allowed = ELM327Client.initializationCommands + OBDPID.allCases.map(\.rawValue) + ["ATRV"]
        guard allowed.contains(command) else { throw OBDError.unsupported }
        guard ready, !closed, peripheral?.state == .connected else { throw OBDError.disconnected }
        guard responseWaiter == nil else { throw OBDError.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                responseWaiter = continuation
                buffer.reset()
                pendingWrite = Data((command + "\r").utf8)
                armDeadline(seconds: timeout)
                flushWrite()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    private func ensureManager() {
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    private func startScanIfPossible() {
        guard manager?.state == .poweredOn else { return }
        // Foreground discovery also finds adapters that omit service UUIDs in advertisements.
        manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func beginConnectionIfPossible() {
        guard connectWaiter != nil, peripheral == nil, let manager, let selectedID else { return }
        switch manager.state {
        case .poweredOn:
            if let saved = discoveredPeripherals[selectedID]
                ?? manager.retrievePeripherals(withIdentifiers: [selectedID]).first {
                attach(saved)
            } else {
                diagnostic = "Поиск сохранённого адаптера…"
                // Service-filtered scans can operate in the background, subject to iOS limits.
                manager.scanForPeripherals(withServices: Self.profiles.map(\.service), options: nil)
            }
        case .unauthorized: fail(OBDError.adapter("Разрешите Bluetooth в настройках iPhone"))
        case .poweredOff: fail(OBDError.adapter("Bluetooth выключен"))
        case .unsupported: fail(OBDError.adapter("BLE недоступен"))
        case .unknown, .resetting: break
        @unknown default: fail(OBDError.disconnected)
        }
    }

    private func attach(_ device: CBPeripheral) {
        guard !closed, peripheral == nil else { return }
        manager?.stopScan()
        peripheral = device
        device.delegate = self
        diagnostic = "Подключение к \(device.name ?? "Vgate")…"
        manager?.connect(device, options: nil)
    }

    private func armDeadline(seconds: TimeInterval) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.fail(OBDError.timeout)
        }
    }

    private func flushWrite() {
        guard let peripheral, let characteristic = writeCharacteristic, let data = pendingWrite else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
        // Whitelisted commands are <= 7 bytes; never truncate a command to the MTU.
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
        completedResponse = nil
        responseWaiter = nil
        waiter.resume(returning: response)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        ready = false
        discovering = false
        deadline?.cancel()
        scanDeadline?.cancel()
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
            fail(OBDError.adapter("Поддерживаемый GATT-профиль не найден"))
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
        guard !closed else { return }
        if central.state != .poweredOn && ready { fail(OBDError.disconnected); return }
        if discovering {
            if central.state == .poweredOn { startScanIfPossible() }
            else if central.state == .unauthorized { diagnostic = "Разрешите Bluetooth в настройках iPhone" }
            else if central.state == .poweredOff { diagnostic = "Bluetooth выключен" }
        }
        beginConnectionIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed else { return }
        if connectWaiter != nil, device.identifier == selectedID { attach(device); return }
        guard discovering else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? device.name ?? "BLE OBD"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let likelyOBD = ["vlink", "v-link", "vgate", "icar", "obd"].contains { name.lowercased().contains($0) }
        guard likelyOBD || Self.profiles.contains(where: { services.contains($0.service) }) else { return }
        if discoveredPeripherals[device.identifier] == nil {
            discoveredPeripherals[device.identifier] = device
            devices.append(BLEDevice(id: device.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard device === peripheral, !closed else { return }
        device.discoverServices(Self.profiles.map(\.service))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }
        fail(error ?? OBDError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }
        fail(error ?? OBDError.disconnected)
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral, !closed else { return }
        if let error { fail(error); return }
        remainingProfiles = Self.profiles.compactMap { candidate in
            guard let service = device.services?.first(where: { $0.uuid == candidate.service }) else { return nil }
            return (profile: candidate, service: service)
        }
        discoverNextProfile(on: device)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral, !closed, let profile, service.uuid == profile.service else { return }
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
            else { discoverNextProfile(on: device) }
            return
        }
        guard !ready, let continuation = connectWaiter else { return }
        ready = true
        deadline?.cancel()
        diagnostic = "BLE готов: \(profile?.service.uuidString ?? "")"
        connectWaiter = nil
        continuation.resume()
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic === notifyCharacteristic, !closed else { return }
        if let error { fail(error); return }
        guard responseWaiter != nil, pendingWrite == nil, let data = characteristic.value else { return }
        do {
            let frames = try buffer.append(data)
            guard !frames.isEmpty else { return }
            guard frames.count == 1, completedResponse == nil else {
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
