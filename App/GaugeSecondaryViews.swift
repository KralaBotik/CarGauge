import CarGaugeCore
import SwiftUI

struct GaugeHistoryView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel

    var body: some View {
        GaugePage {
            GaugeHeading(title: "История", subtitle: model.isRunning ? "Текущий сеанс" : "Последний сеанс")
            SourceIndicator(source: model.source)
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Температура за сеанс").font(.headline)
                    Text("До 30 минут · пропуски видны на графике").font(.caption).foregroundStyle(palette.muted)
                    WarmupChart(points: model.history, thresholds: model.thresholds, compact: false, alert: model.level)
                }
            }
            if let first = model.history.first, let last = model.history.last {
                GaugePanel {
                    VStack(spacing: GaugeSpacing.medium) {
                        LabeledContent("Первый замер", value: "\(Int(first.reading.value)) °C")
                        LabeledContent("Последний замер", value: "\(Int(last.reading.value)) °C")
                        if let maximum = model.history.map(\.reading.value).max() {
                            LabeledContent("Максимум", value: "\(Int(maximum)) °C")
                        }
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
                .accessibilityIdentifier("session-history")
            }
        }
        .accessibilityIdentifier("history-screen")
    }
}

struct GaugeDiagnosticsView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel

    var body: some View {
        GaugePage {
            GaugeHeading(title: "Диагностика", subtitle: "Связь и источник показаний")
            SourceIndicator(source: model.source)
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Соединение").font(.headline)
                    Text(model.status)
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("diagnostic-status")
                    if model.source == .vehicle {
                        AdapterControls(ble: model.ble, isRunning: model.isRunning,
                                        onDiscover: model.discoverAdapters, onSelect: model.selectDevice)
                    } else {
                        Text("В режиме симулятора Bluetooth не используется.")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                    }
                }
                .font(.subheadline)
            }
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Параметры OBD-II").font(.headline)
                    LabeledContent("Температура ОЖ", value: "PID 0105")
                        .accessibilityIdentifier("coolant-pid")
                    LabeledContent("Обороты", value: "PID 010C")
                    LabeledContent("Напряжение", value: voltageSource)
                }
                .font(.subheadline)
            }
        }
        .accessibilityIdentifier("diagnostics-screen")
    }

    private var voltageSource: String {
        switch model.supplementary?.voltageSource {
        case .ecu: "ECU · PID 0142"
        case .adapter: "Адаптер · ATRV"
        case nil: "0142 / ATRV"
        }
    }
}

private struct AdapterControls: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var ble: BLETransport
    let isRunning: Bool
    let onDiscover: () -> Void
    let onSelect: (UUID) -> Void

    var body: some View {
        Text(ble.diagnostic).foregroundStyle(palette.muted)
        if !isRunning {
            Button("Найти Vgate по Bluetooth", action: onDiscover)
                .buttonStyle(GaugeActionStyle(emphasized: true))
                .accessibilityIdentifier("discover-adapter")
            ForEach(ble.devices) { device in
                Button {
                    onSelect(device.id)
                } label: {
                    LabeledContent(device.name, value: "\(device.rssi) dBm")
                }
                .buttonStyle(GaugeActionStyle())
            }
        }
    }
}

struct GaugeSettingsView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel
    @Binding var appearance: GaugeAppearance
    let isActive: Bool

    var body: some View {
        GaugePage {
            GaugeHeading(title: "Настройки")
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Оформление").font(.headline)
                    Picker("Тема", selection: $appearance) {
                        ForEach(GaugeAppearance.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance-picker")
                }
            }
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Температурные пороги").font(.headline).accessibilityAddTraits(.isHeader)
                    thresholdStepper(.operating, title: "Рабочая температура", id: "operating-threshold")
                    thresholdStepper(.warning, title: "Предупреждение", id: "warning-threshold")
                    thresholdStepper(.critical, title: "Перегрев", id: "critical-threshold")
                    Button("Восстановить исходные пороги") { model.resetThresholds() }
                        .buttonStyle(GaugeActionStyle())
                        .disabled(model.thresholds == .standard)
                        .accessibilityIdentifier("reset-thresholds")
                    Text("Это пороги CarGauge. Сверяйтесь со штатной индикацией автомобиля.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Автомобиль").font(.headline)
                    Toggle("Автоматически при запуске", isOn: $model.autoConnect)
                        .tint(palette.operating)
                        .accessibilityIdentifier("auto-connect")
                    Button("Разрешить уведомления о температуре") {
                        Task { await model.requestWarningNotifications() }
                    }
                    .buttonStyle(GaugeActionStyle())
                }
            }
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Симулятор").font(.headline)
                    Picker("Сценарий", selection: Binding(get: { model.scenario }, set: { model.setScenario($0) })) {
                        Text("Прогрев").tag(SimulationScenario.warmup)
                        Text("Перегрев").tag(SimulationScenario.overheat)
                        Text("Напряжение через ATRV").tag(SimulationScenario.noVoltagePID)
                        Text("Обрыв связи").tag(SimulationScenario.disconnect)
                        Text("Обрыв и восстановление").tag(SimulationScenario.reconnect)
                        Text("Нет PID температуры").tag(SimulationScenario.missingCoolant)
                        Text("Некорректная температура").tag(SimulationScenario.invalidCoolant)
                        Text("Зависший адаптер").tag(SimulationScenario.hangingAdapter)
                        Text("Остановка двигателя").tag(SimulationScenario.engineOff)
                    }
                    .accessibilityIdentifier("simulation-scenario")
                }
            }
            #if !CARGAUGE_BASIC
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Экран блокировки и CarPlay").font(.headline)
                    Toggle("Запускать Live Activity автоматически", isOn: $model.autoLiveActivity)
                        .tint(palette.operating)
                        .accessibilityIdentifier("auto-live-activity")
                    if !model.widgetContainerAvailable {
                        Text("Общий контейнер виджета недоступен. Проверьте подпись Full.")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                            .accessibilityIdentifier("unavailable-app-group")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button(model.activityIsRunning ? "Завершить Live Activity" : "Начать Live Activity") {
                            model.toggleActivity()
                        }
                        .buttonStyle(GaugeActionStyle())
                        .disabled(!model.activityIsRunning && (!isActive || model.coolant?.isFresh(at: context.date) != true))
                        .accessibilityIdentifier("live-activity-button")
                    }
                }
            }
            #endif
            if let message = model.presentationMessage {
                Text(message).font(.footnote).foregroundStyle(palette.muted)
            }
        }
        .accessibilityIdentifier("settings-screen")
    }

    private func thresholdStepper(_ limit: ThermalThresholds.Limit, title: String, id: String) -> some View {
        let binding = Binding(get: { model.thresholds[limit] }, set: { model.setThreshold(limit, to: $0) })
        return Stepper(value: binding, in: model.thresholds.range(for: limit)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text("\(model.thresholds[limit]) °C")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier(id + "-value")
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: "\(model.thresholds[limit]) °C"))
        .accessibilityIdentifier(id)
    }
}
