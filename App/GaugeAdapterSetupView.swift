import SwiftUI
import UIKit

struct GaugeAdapterSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationStack {
            AdapterList(model: model, ble: model.ble)
                .navigationTitle("Найти адаптер")
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
        .onAppear { model.discoverAdapters() }
        .onDisappear { model.leaveAdapterSetup() }
        .onChange(of: model.phase) { _, phase in
            if phase == .streaming && model.hasConfiguredAdapter { dismiss() }
        }
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
        BLEDevice(id: UUID(), name: "Vgate iCar Pro BLE", rssi: -48),
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
            Text("Выберите свой адаптер. CarGauge проверит связь с блоком управления и сохранит адаптер после первого замера.")
                .font(.subheadline).foregroundStyle(palette.muted)
            if model.isCheckingSelection {
                GaugePanel {
                    ProgressView("Проверяем адаптер и ЭБУ…")
                        .accessibilityIdentifier("validating-adapter")
                }
            } else {
                discoveryStatus
                deviceGroup("Вероятные OBD-II адаптеры", devices: nearby.filter(\.matchesVgateName), id: "likely-adapters")
                deviceGroup("Другие устройства", devices: nearby.filter { !$0.matchesVgateName }, id: "other-devices")
                if scanState == .finished || scanState == .idle {
                    Button("Обновить список") { model.discoverAdapters(extended: expanded) }
                        .buttonStyle(GaugeActionStyle())
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
        if model.phase == .failed && ble.isClosed {
            Text("Проверка не прошла. Проверьте питание и зажигание, затем обновите список.")
                .foregroundStyle(palette.warning)
        }
        switch scanState {
        case .scanning:
            ProgressView("Ищем адаптеры поблизости…").accessibilityIdentifier("scanning-adapters")
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
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(id)
                    ForEach(devices) { device in
                        Button { model.selectDevice(device.id) } label: {
                            Label(device.hasName ? device.name : "Устройство без имени",
                                  systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(GaugeActionStyle())
                        .disabled(model.isRunning || ble.isClosed)
                    }
                }
            }
        }
    }
}
