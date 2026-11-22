import CarGaugeCore
import Foundation
import SwiftUI
import UIKit

struct GaugeAdapterSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationStack {
            AdapterList(model: model, ble: model.discoveryBLE)
                .navigationTitle("Подключение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.isCheckingSelection ? "Отменить" : "Закрыть") {
                            model.leaveAdapterSetup()
                            dismiss()
                        }
                        .accessibilityIdentifier("close-adapter-setup")
                    }
                }
        }
        .interactiveDismissDisabled(model.isCheckingSelection)
        .onAppear { model.openAdapterSetup() }
        .onDisappear { model.leaveAdapterSetup() }
        .onChange(of: model.completedAdapterSelection) { _, _ in dismiss() }
    }
}

private struct AdapterList: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: DashboardModel
    @ObservedObject var ble: BLETransport
    @State private var expanded = false
    #if DEBUG
    private static let fixtureDevices = [
        BLEDevice(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x7A, 0x12, 0xA4, 0x81, 0xB0, 0x01)),
                  name: "Vgate iCar Pro BLE", rssi: -48),
        BLEDevice(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x7A, 0x12, 0xA4, 0x81, 0xB0, 0x02)),
                  name: "Vgate iCar Pro BLE", rssi: -56),
        BLEDevice(id: UUID(), name: "IOS-VLINK", rssi: -58),
        BLEDevice(id: UUID(), name: "Устройство рядом", rssi: -60),
        BLEDevice(id: UUID(), name: "", rssi: -66),
    ]
    #endif

    private var devices: [BLEDevice] {
        #if DEBUG
        if model.discoveryFixture {
            return Self.fixtureDevices.filter { expanded || $0.hasName }
        }
        #endif
        return ble.devices
    }

    private var scanState: BLEScanState {
        #if DEBUG
        if model.discoveryFixture { return .finished }
        #endif
        return ble.scanState
    }

    var body: some View {
        let nearby = devices
        GaugePage {
            GaugeHeading(title: "Адаптеры рядом", subtitle: "Коснитесь своего адаптера. Сохраним его, когда автомобиль ответит.")
            if model.isCheckingSelection {
                GaugeRule()
                ProgressView("Проверяем связь с автомобилем…")
                    .tint(palette.accent)
                    .accessibilityIdentifier("validating-adapter")
            } else {
                discoveryStatus
                deviceGroup("Вероятные OBD-II адаптеры", devices: nearby.filter(\.hasOBDName), id: "likely-adapters")
                deviceGroup("Другие устройства", devices: nearby.filter { !$0.hasOBDName }, id: "other-devices")
                if scanState == .finished || scanState == .idle {
                    Button("Обновить список") { model.discoverAdapters(extended: expanded) }
                        .buttonStyle(GaugeActionStyle(emphasized: nearby.isEmpty))
                        .accessibilityIdentifier("rescan-adapters")
                }
                if !expanded && (scanState == .finished || scanState == .scanning || scanState == .idle) {
                    Button("Искать безымянные устройства") {
                        expanded = true
                        model.discoverAdapters(extended: true)
                    }
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("extended-discovery")
                }
            }
        }
        .accessibilityIdentifier("adapter-setup")
    }

    @ViewBuilder private var discoveryStatus: some View {
        if let message = model.adapterSetupMessage {
            Text(message).foregroundStyle(palette.warning)
        }
        switch scanState {
        case .scanning:
            ProgressView("Ищем устройства…").tint(palette.accent)
                .accessibilityIdentifier("scanning-adapters")
        case .poweredOff:
            Text("Включите Bluetooth на iPhone, затем обновите список.").foregroundStyle(palette.warning)
            Button("Обновить список") { model.discoverAdapters(extended: expanded) }
                .buttonStyle(GaugeActionStyle())
        case .unauthorized:
            Text("Разрешите CarGauge доступ к Bluetooth в настройках iPhone.")
            Button("Открыть настройки iPhone") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(GaugeActionStyle())
        case .unavailable:
            Text("Сейчас Bluetooth недоступен. Попробуйте снова.").foregroundStyle(palette.warning)
            Button("Обновить список") { model.discoverAdapters(extended: expanded) }
                .buttonStyle(GaugeActionStyle())
        case .finished where devices.isEmpty:
            Text("Ничего не нашли. Проверьте питание адаптера и попробуйте снова.")
                .accessibilityIdentifier("no-adapters-found")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func deviceGroup(_ title: String, devices: [BLEDevice], id: String) -> some View {
        if !devices.isEmpty {
            GaugeSection(title: title, headerID: id) {
                VStack(spacing: 0) {
                    ForEach(devices) { device in
                        adapterRow(device, among: devices)
                        if device.id != devices.last?.id { GaugeRule() }
                    }
                }
            }
        }
    }

    private func adapterRow(_ device: BLEDevice, among peers: [BLEDevice]) -> some View {
        let title = device.hasName ? device.name : "Устройство без имени"
        let duplicates = peers.filter {
            $0.id != device.id && $0.name.caseInsensitiveCompare(device.name) == .orderedSame
        }.map(\.id)
        let suffix = BLEAdvertisementName.disambiguatingID(device.id, against: duplicates)
        let identifier = !device.hasName || !duplicates.isEmpty ? "ID · \(suffix)" : nil

        return Button { model.selectDevice(device.id) } label: {
            HStack(spacing: GaugeSpacing.medium) {
                Image(systemName: device.hasOBDName ? "car.side" : "dot.radiowaves.left.and.right")
                    .imageScale(.medium)
                    .foregroundStyle(device.hasOBDName ? palette.accent : palette.muted)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                    Text(title).font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let identifier {
                        Text(identifier).font(.caption.monospaced()).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: GaugeSpacing.xsmall)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.muted)
            }
            .padding(.vertical, GaugeSpacing.medium)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text)
        .accessibilityLabel(title)
        .accessibilityValue(identifier ?? "")
        .accessibilityIdentifier("adapter-\(device.id.uuidString)")
    }
}
