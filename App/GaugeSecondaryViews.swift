import CarGaugeCore
import SwiftUI

struct GaugeHistoryView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel

    var body: some View {
        GaugePage {
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Температура за сеанс").font(.headline)
                    Text("До 30 минут · пропуски видны на графике").font(.caption).foregroundStyle(palette.muted)
                    WarmupChart(points: model.history, thresholds: model.thresholds, compact: false,
                                alert: model.level, tripStartedAt: model.tripStartedAt)
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
    @ObservedObject var ble: BLETransport

    var body: some View {
        GaugePage {
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                    Text("Соединение").font(.headline)
                    LabeledContent("Адаптер", value: model.configuredName ?? (model.hasConfiguredAdapter ? "Сохранён" : "Не настроен"))
                    Text(ble.diagnostic).foregroundStyle(palette.muted)
                    LabeledContent("Этап проверки", value: model.adapterStage)
                    Text(model.status)
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("diagnostic-status")
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
            #if !CARGAUGE_BASIC
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Виджет").font(.headline)
                    Text(model.widgetContainerAvailable
                         ? "Приложение видит общий контейнер. Проверьте показания в самом виджете."
                         : "Общий контейнер недоступен. Для виджета нужна подпись Full с App Groups.")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                        .accessibilityIdentifier("widget-container-state")
                }
            }
            #endif
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

struct GaugeSettingsView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel
    @Binding var appearance: GaugeAppearance
    let isActive: Bool
    let showAdapter: () -> Void
    let showDiagnostics: () -> Void
    @State private var confirmsReset = false

    var body: some View {
        GaugePage {
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Адаптер OBD-II").font(.headline)
                    if let name = model.configuredName {
                        Text(name).font(.subheadline).foregroundStyle(palette.muted)
                    }
                    Button(model.hasConfiguredAdapter ? "Сменить адаптер" : "Найти адаптер", action: showAdapter)
                        .buttonStyle(GaugeActionStyle())
                        .accessibilityIdentifier("change-adapter")
                    Toggle("Подключаться при открытии", isOn: $model.autoConnect)
                        .tint(palette.operating)
                        .accessibilityIdentifier("auto-connect")
                    if model.isRunning {
                        Button("Остановить измерения") { model.stop() }
                            .buttonStyle(GaugeActionStyle())
                            .accessibilityIdentifier("stop-measurement")
                    }
                    if model.canRetryConnection {
                        Button("Забыть адаптер", role: .destructive) { confirmsReset = true }
                            .accessibilityIdentifier("forget-adapter")
                    }
                }
            }
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
                    Text("Уведомления").font(.headline)
                    Button("Разрешить предупреждения о температуре") {
                        Task { await model.requestWarningNotifications() }
                    }
                    .buttonStyle(GaugeActionStyle())
                }
            }
            #if !CARGAUGE_BASIC
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    Text("Экран блокировки и CarPlay").font(.headline)
                    Toggle("Запускать Live Activity автоматически", isOn: $model.autoLiveActivity)
                        .tint(palette.operating)
                        .accessibilityIdentifier("auto-live-activity")
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
            Button(action: showDiagnostics) {
                Label("Диагностика", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(GaugeActionStyle())
            .accessibilityIdentifier("diagnostics-nav")
            if let message = model.presentationMessage {
                Text(message).font(.footnote).foregroundStyle(palette.muted)
            }
        }
        .accessibilityIdentifier("settings-screen")
        .confirmationDialog("Забыть сохранённый адаптер?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Забыть адаптер", role: .destructive) { model.resetAdapter() }
            Button("Отмена", role: .cancel) {}
        }
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
