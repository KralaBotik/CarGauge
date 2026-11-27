import CarGaugeCore
import Foundation
import SwiftUI
import UIKit

struct GaugeAdapterSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationStack {
            AdapterList(model: model, ble: model.discoveryBLE, cancel: close)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !model.isCheckingSelection {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть", action: close)
                                .accessibilityIdentifier("close-adapter-setup")
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.isCheckingSelection)
        .onAppear { model.openAdapterSetup() }
        .onDisappear { model.leaveAdapterSetup() }
        .onChange(of: model.completedAdapterSelection) { _, _ in dismiss() }
    }

    private func close() {
        model.leaveAdapterSetup()
        dismiss()
    }
}

private struct AdapterList: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: DashboardModel
    @ObservedObject var ble: BLETransport
    let cancel: () -> Void
    @State private var expanded = false
    @State private var showsOtherDevices = false
    #if DEBUG
    private static let emptyFixture = ProcessInfo.processInfo.arguments.contains("--empty-adapter-list-fixture")
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
            return Self.emptyFixture ? [] : Self.fixtureDevices.filter { expanded || $0.hasName }
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
        let likely = nearby.filter(\.hasOBDName)
        let other = nearby.filter { !$0.hasOBDName }
        GaugePage(spacing: GaugeSpacing.large) {
            if model.isCheckingSelection {
                VStack(alignment: .leading, spacing: GaugeSpacing.large) {
                    ProgressView().tint(palette.accent).accessibilityHidden(true)
                    GaugeHeading(title: "Проверяем адаптер",
                                 subtitle: "Дождитесь ответа автомобиля. Оставьте зажигание включённым.")
                        .accessibilityIdentifier("validating-adapter")
                }
                .padding(.vertical, GaugeSpacing.section)
            } else {
                GaugeHeading(title: "Адаптеры рядом",
                             subtitle: "Выберите свой адаптер. Сохраним его после ответа автомобиля.")
                #if DEBUG
                if model.discoveryFixture { SourceIndicator(source: .simulator) }
                #endif
                discoveryStatus
                if canDiscover {
                    if !likely.isEmpty {
                        GaugeSection(title: "Вероятные OBD-II адаптеры", headerID: "likely-adapters") {
                            deviceRows(likely)
                        }
                    }
                    if !other.isEmpty {
                        GaugeSection(title: "Другие устройства", headerID: "other-devices") {
                            if !likely.isEmpty {
                                otherDevicesDisclosure(count: other.count)
                            }
                            if likely.isEmpty || showsOtherDevices {
                                deviceRows(other)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions(emphasizesRescan: nearby.isEmpty)
        }
        .sensoryFeedback(.selection, trigger: showsOtherDevices)
        .accessibilityIdentifier("adapter-setup")
    }

    private var canDiscover: Bool {
        switch scanState {
        case .idle, .scanning, .finished: true
        case .poweredOff, .unauthorized, .unavailable: false
        }
    }

    @ViewBuilder private func actions(emphasizesRescan: Bool) -> some View {
        if model.isCheckingSelection {
            bottomActions {
                Button("Отменить проверку", action: cancel)
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("close-adapter-setup")
            }
        } else if scanState == .unauthorized {
            bottomActions {
                Button("Открыть настройки iPhone") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(GaugeActionStyle(emphasized: true))
            }
        } else if scanState != .scanning || !expanded {
            bottomActions {
                if scanState != .scanning {
                    Button("Обновить список") { model.discoverAdapters(extended: expanded) }
                        .buttonStyle(GaugeActionStyle(emphasized: emphasizesRescan))
                        .accessibilityIdentifier("rescan-adapters")
                }
                if !expanded && canDiscover {
                    Button("Искать безымянные устройства") {
                        expanded = true
                        showsOtherDevices = true
                        model.discoverAdapters(extended: true)
                    }
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("extended-discovery")
                }
            }
        }
    }

    private func bottomActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            GaugeRule()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: GaugeSpacing.small, content: content)
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: GaugeSpacing.small, content: content)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, GaugeSpacing.page)
            .padding(.vertical, GaugeSpacing.small)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .background(palette.canvas, ignoresSafeAreaEdges: .bottom)
    }

    @ViewBuilder private var discoveryStatus: some View {
        if let message = model.adapterSetupMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(palette.warning)
        }
        switch scanState {
        case .scanning:
            ProgressView("Ищем устройства…").tint(palette.accent)
                .accessibilityIdentifier("scanning-adapters")
        case .poweredOff:
            Label("Включите Bluetooth на iPhone, затем обновите список.", systemImage: "bolt.slash")
                .foregroundStyle(palette.warning)
        case .unauthorized:
            Label("Разрешите CarGauge доступ к Bluetooth в настройках iPhone.", systemImage: "lock")
        case .unavailable:
            Label("Bluetooth недоступен. Попробуйте обновить список.", systemImage: "exclamationmark.circle")
                .foregroundStyle(palette.warning)
        case .finished where devices.isEmpty:
            Text("Адаптер не найден. Проверьте питание адаптера и зажигание.")
                .foregroundStyle(palette.muted)
                .accessibilityIdentifier("no-adapters-found")
        default:
            EmptyView()
        }
    }

    private func otherDevicesDisclosure(count: Int) -> some View {
        Button {
            showsOtherDevices.toggle()
        } label: {
            HStack(spacing: GaugeSpacing.small) {
                Text(showsOtherDevices ? "Скрыть список" : "Показать список")
                Spacer()
                Text(count.formatted()).monospacedDigit()
                Image(systemName: showsOtherDevices ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsOtherDevices ? "Скрыть другие устройства" : "Показать другие устройства")
        .accessibilityValue("\(count)")
        .accessibilityIdentifier("other-devices-disclosure")
    }

    private func deviceRows(_ devices: [BLEDevice]) -> some View {
        VStack(spacing: 0) {
            ForEach(devices) { device in
                adapterRow(device, among: devices)
                if device.id != devices.last?.id { GaugeRule() }
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
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                    Text(verbatim: title).font(.body.weight(.medium))
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
                    .accessibilityHidden(true)
            }
            .padding(.vertical, GaugeSpacing.small)
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
