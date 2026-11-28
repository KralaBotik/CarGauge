import CarGaugeCore
import SwiftUI

struct GaugeHistoryView: View {
    @Environment(\.gaugePalette) private var palette
    @ObservedObject var model: DashboardModel

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            if let first = model.history.first, let last = model.history.last {
                GaugeHeading(title: "Температура за сеанс", subtitle: "До 30 минут текущей или последней поездки.")
                #if DEBUG
                if model.source == .simulator { SourceIndicator(source: model.source) }
                #endif
                WarmupChart(points: model.history, thresholds: model.thresholds, compact: false,
                            alert: model.level, tripStartedAt: model.tripStartedAt)
                GaugeSection(title: "Сводка замеров") {
                    LabeledContent("В начале", value: "\(Int(first.reading.value)) °C")
                    LabeledContent("Последний замер", value: "\(Int(last.reading.value)) °C")
                    if let maximum = model.history.map(\.reading.value).max() {
                        LabeledContent("Максимум", value: "\(Int(maximum)) °C")
                    }
                }
                .monospacedDigit()
                .accessibilityIdentifier("session-history")
            } else {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                GaugeHeading(title: "Температура за сеанс",
                             subtitle: "Здесь появится график, когда CarGauge получит температуру от автомобиля.")
            }
            if model.source == .vehicle || model.drive.isFixture {
                DriveHistorySection(drive: model.drive)
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
        GaugePage(spacing: GaugeSpacing.section) {
            GaugeHeading(title: model.connectionTitle, subtitle: model.status)
                .accessibilityIdentifier("diagnostic-status")

            #if DEBUG
            if model.source == .simulator && !model.drive.isFixture { SourceIndicator(source: model.source) }
            #endif
            if model.source == .vehicle {
                GaugeSection(title: "Соединение") {
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
                diagnosticField("Маски поддержки PID", model.pidSupportSummary)
                    .accessibilityIdentifier("pid-support-summary")
            }
            GaugeDiagnosticSurveyView(model: model)
            if model.source == .vehicle || model.drive.isFixture {
                VehicleHealthSection(drive: model.drive, health: model.drive.health) {
                    Task { await model.requestWarningNotifications() }
                }
                DriveDiagnosticHistory(drive: model.drive)
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
        #if DEBUG
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.drive.isFixture { DiagnosticFixtureBanner() }
        }
        #endif
    }

    private func diagnosticField(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
            GaugeSection(title: "Автомобиль") {
                if let name = model.configuredName {
                    LabeledContent("Адаптер", value: name)
                        .font(.subheadline)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Сохранённый адаптер")
                        .accessibilityValue(Text(verbatim: name))
                        .accessibilityIdentifier("configured-adapter")
                }
                Toggle("Подключаться при открытии", isOn: $model.autoConnect)
                    .tint(palette.operating)
                    .accessibilityIdentifier("auto-connect")
                Button(model.hasConfiguredAdapter ? "Сменить адаптер" : "Найти адаптер", action: showAdapter)
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("change-adapter")
                if model.isRunning {
                    Button("Остановить измерения") { model.stop() }
                        .buttonStyle(GaugeActionStyle())
                        .accessibilityIdentifier("stop-measurement")
                }
                if model.canRetryConnection {
                    Button("Забыть адаптер", role: .destructive) { confirmsReset = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("forget-adapter")
                }
            }

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

            GaugeSection(title: "Температурные пороги") {
                thresholdStepper(.operating, title: "Рабочая температура", id: "operating-threshold")
                thresholdStepper(.warning, title: "Предупреждение", id: "warning-threshold")
                thresholdStepper(.critical, title: "Перегрев", id: "critical-threshold")
                Button("Восстановить исходные пороги") { model.resetThresholds() }
                    .buttonStyle(GaugeActionStyle())
                    .disabled(model.thresholds == .standard)
                    .accessibilityIdentifier("reset-thresholds")
                Text("Пороги задают предупреждения CarGauge. Сверяйтесь со штатной индикацией автомобиля.")
                    .font(.caption).foregroundStyle(palette.muted)
            }

            #if !CARGAUGE_BASIC
            GaugeSection(title: "Экран блокировки и CarPlay") {
                Toggle("Автоматическая Live Activity", isOn: $model.autoLiveActivity)
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
                if let message = model.presentationMessage {
                    Text(message).font(.footnote).foregroundStyle(palette.muted)
                }
            }
            #endif

            GaugeSection(title: "Уведомления") {
                Button("Разрешить предупреждения о температуре") {
                    Task { await model.requestWarningNotifications() }
                }
                .buttonStyle(GaugeActionStyle())
                if let message = model.notificationMessage {
                    Text(message).font(.footnote).foregroundStyle(palette.muted)
                }
            }

            GaugeRule()
            Button(action: showDiagnostics) {
                Label("Диагностика", systemImage: "waveform.path.ecg")
            }
            .buttonStyle(GaugeActionStyle())
            .accessibilityIdentifier("diagnostics-nav")
            DriveSettingsSection(drive: model.drive)
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
