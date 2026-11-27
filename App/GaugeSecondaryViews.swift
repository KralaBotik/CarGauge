import CarGaugeCore
import Foundation
import SwiftUI

struct GaugeHistoryView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel

    var body: some View {
        GaugePage(spacing: GaugeSpacing.large) {
            if let first = model.history.first, let last = model.history.last {
                GaugeHeading(title: "Температура за сеанс", subtitle: "До 30 минут поездки")
                #if DEBUG
                if model.source == .simulator { SourceIndicator(source: model.source) }
                #endif
                WarmupChart(points: model.history, thresholds: model.thresholds, compact: false,
                            alert: model.level, tripStartedAt: model.tripStartedAt)
                GaugeRule()
                TripReadings(first: first.reading.value, last: last.reading.value,
                             peak: model.history.lazy.map(\.reading.value).max() ?? last.reading.value)
                    .accessibilityIdentifier("session-history")
            } else {
                VStack(alignment: .leading, spacing: GaugeSpacing.large) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title.weight(.light))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    GaugeHeading(title: "Температура за сеанс",
                                 subtitle: "График прогрева появится после первого замера с автомобиля.")
                }
                .padding(.top, GaugeSpacing.section)
            }
        }
        .accessibilityIdentifier("history-screen")
    }
}

private struct TripReadings: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    let first: Double
    let last: Double
    let peak: Double

    var body: some View {
        let layout = typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: GaugeSpacing.medium))
        layout {
            reading("Первый", first)
            reading("Последний", last)
            reading("Максимум", peak)
        }
    }

    private func reading(_ title: String, _ temperature: Double) -> some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(palette.muted)
            Text("\(Int(temperature)) °C").font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(temperature)) градусов Цельсия")
    }
}

struct GaugeDiagnosticsView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel
    @ObservedObject var ble: BLETransport

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            GaugeHeading(title: model.connectionTitle, subtitle: model.status)
                .accessibilityIdentifier("diagnostic-status")

            #if DEBUG
            if model.source == .simulator { SourceIndicator(source: model.source) }
            #endif
            if model.source == .vehicle {
                GaugeSection(title: "Канал связи") {
                    diagnosticField("Адаптер", model.configuredName ?? (model.hasConfiguredAdapter ? "Сохранён" : "Не настроен"))
                    diagnosticField("Bluetooth", ble.diagnostic)
                    diagnosticField("Обмен с автомобилем", model.adapterStage)
                }
            }

            GaugeSection(title: "Параметры OBD-II") {
                LabeledContent("Температура ОЖ", value: "PID 0105")
                    .accessibilityIdentifier("coolant-pid")
                LabeledContent("Обороты", value: "PID 010C")
                LabeledContent("Напряжение", value: voltageSource)
                diagnosticField("Маски поддержки PID",
                                model.pidSupportSummary.replacingOccurrences(of: " · ", with: "\n"))
                    .accessibilityIdentifier("pid-support-summary")
            }
            #if !CARGAUGE_BASIC
            GaugeSection(title: "Общий контейнер виджета") {
                Text(model.widgetContainerAvailable
                     ? "Доступен приложению. Откройте виджет, чтобы проверить обмен."
                     : "Недоступен после текущей подписи. Виджету нужен общий App Group приложения и расширения.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                    .accessibilityIdentifier("widget-container-state")
            }
            #endif
        }
        .accessibilityIdentifier("diagnostics-screen")
    }

    private func diagnosticField(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(name).font(.caption).foregroundStyle(palette.muted)
            Text(value).font(.subheadline)
        }
    }

    private var voltageSource: String {
        guard let snapshot = model.supplementary, snapshot.voltage != nil else { return "0142 / ATRV" }
        return snapshot.voltageSource == .ecu ? "ЭБУ · PID 0142" : "Адаптер · ATRV"
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
        GaugePage(spacing: GaugeSpacing.section) {
            connectionSettings
            appearanceSettings
            temperatureSettings
            #if !CARGAUGE_BASIC
            presentationSettings
            #endif
            notificationSettings
        }
        .accessibilityIdentifier("settings-screen")
        .confirmationDialog("Забыть сохранённый адаптер?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Забыть адаптер", role: .destructive) { model.resetAdapter() }
            Button("Отмена", role: .cancel) {}
        }
        .sensoryFeedback(.selection, trigger: appearance.rawValue)
    }

    private var connectionSettings: some View {
        GaugeSection(title: "Автомобиль") {
            VStack(alignment: .leading, spacing: 0) {
                if let name = model.configuredName {
                    VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                        Text("Сохранённый адаптер").font(.caption).foregroundStyle(palette.muted)
                        Text(verbatim: name).font(.headline)
                    }
                    .padding(.vertical, GaugeSpacing.small)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Сохранённый адаптер")
                    .accessibilityValue(Text(verbatim: name))
                    .accessibilityIdentifier("configured-adapter")
                    GaugeRule()
                }
                Toggle("Подключаться при открытии", isOn: $model.autoConnect)
                    .tint(palette.operating)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("auto-connect")
                GaugeRule()
                actionRow(model.hasConfiguredAdapter ? "Сменить адаптер" : "Найти адаптер",
                          symbol: "dot.radiowaves.left.and.right", id: "change-adapter", disclosure: true, action: showAdapter)
                GaugeRule()
                actionRow("Диагностика", symbol: "waveform.path.ecg", id: "diagnostics-nav",
                          disclosure: true, action: showDiagnostics)
                if model.isRunning {
                    GaugeRule()
                    actionRow("Остановить измерения", symbol: "pause.circle", id: "stop-measurement") { model.stop() }
                }
                if model.canRetryConnection {
                    GaugeRule()
                    actionRow("Забыть адаптер", symbol: "link.badge.minus", id: "forget-adapter",
                              role: .destructive) { confirmsReset = true }
                }
            }
        }
    }

    private var appearanceSettings: some View {
        GaugeSection(title: "Оформление") {
            Picker("Тема", selection: $appearance) {
                ForEach(GaugeAppearance.allCases, id: \.rawValue) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("appearance-picker")
        }
    }

    private var temperatureSettings: some View {
        GaugeSection(title: "Температурные пороги") {
            VStack(spacing: 0) {
                thresholdStepper(.operating, title: "Рабочая температура", id: "operating-threshold")
                GaugeRule()
                thresholdStepper(.warning, title: "Предупреждение", id: "warning-threshold")
                GaugeRule()
                thresholdStepper(.critical, title: "Перегрев", id: "critical-threshold")
                GaugeRule()
                actionRow("Восстановить исходные пороги", symbol: "arrow.counterclockwise", id: "reset-thresholds") {
                    model.resetThresholds()
                }
                .disabled(model.thresholds == .standard)
            }
            Text("Эти пороги управляют предупреждениями CarGauge. Сверяйтесь со штатной индикацией автомобиля.")
                .font(.footnote).foregroundStyle(palette.muted)
        }
    }

    #if !CARGAUGE_BASIC
    private var presentationSettings: some View {
        GaugeSection(title: "Экран блокировки и CarPlay") {
            VStack(spacing: 0) {
                Toggle("Автоматическая Live Activity", isOn: $model.autoLiveActivity)
                    .tint(palette.operating)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("auto-live-activity")
                GaugeRule()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    actionRow(model.activityIsRunning ? "Завершить Live Activity" : "Начать Live Activity",
                              symbol: model.activityIsRunning ? "stop.circle" : "play.circle",
                              id: "live-activity-button") { model.toggleActivity() }
                        .disabled(!model.activityIsRunning && (!isActive || model.coolant?.isFresh(at: context.date) != true))
                }
            }
            if let message = model.presentationMessage {
                Text(message).font(.footnote).foregroundStyle(palette.muted)
            }
        }
    }
    #endif

    private var notificationSettings: some View {
        GaugeSection(title: "Уведомления") {
            actionRow("Разрешить предупреждения о температуре", symbol: "bell", id: "temperature-notifications") {
                Task { await model.requestWarningNotifications() }
            }
            if let message = model.notificationMessage {
                Text(message).font(.footnote).foregroundStyle(palette.muted)
            }
        }
    }

    private func actionRow(_ title: String, symbol: String, id: String, disclosure: Bool = false,
                           role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: GaugeSpacing.medium) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, GaugeSpacing.small)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle(destructive: role == .destructive))
        .accessibilityIdentifier(id)
    }

    private func thresholdStepper(_ limit: ThermalThresholds.Limit, title: String, id: String) -> some View {
        let binding = Binding(get: { model.thresholds[limit] }, set: { model.setThreshold(limit, to: $0) })
        return Stepper(value: binding, in: model.thresholds.range(for: limit)) {
            VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                Text(title).font(.subheadline)
                Text("\(model.thresholds[limit]) °C")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier(id + "-value")
            }
        }
        .padding(.vertical, GaugeSpacing.small)
        .frame(minHeight: 48)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: "\(model.thresholds[limit]) °C"))
        .accessibilityIdentifier(id)
    }
}

private struct SettingsRowStyle: ButtonStyle {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(isEnabled ? (destructive ? palette.critical : palette.text) : palette.muted)
            .opacity(configuration.isPressed ? 0.58 : 1)
    }
}
