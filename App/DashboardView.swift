import CarGaugeCore
import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let isActive: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        measurements(at: context.date)
                    }
                    warmupChart
                    controls
                }
                .frame(maxWidth: 580)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("CarGauge")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hyundai Elantra HD · G4FC")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Источник", selection: Binding(get: { model.source }, set: { model.switchSource(to: $0) })) {
                Text("Симулятор").tag(DataSource.simulator)
                Text("Автомобиль").tag(DataSource.vehicle)
            }
            .pickerStyle(.segmented)
            Label(model.status, systemImage: model.isRunning ? "dot.radiowaves.left.and.right" : "circle")
                .font(.subheadline)
                .accessibilityIdentifier("connection-status")
        }
    }

    private func measurements(at now: Date) -> some View {
        let reading = model.coolant.flatMap { $0.isFresh(at: now) ? $0 : nil }
        let rpm = model.supplementary?.rpm.flatMap { $0.isFresh(at: now) ? $0 : nil }
        let voltage = model.supplementary?.voltage.flatMap { $0.isFresh(at: now) ? $0 : nil }
        let temperature = reading.map { "\(Int($0.value)) °C" } ?? "—"

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Температура ОЖ", systemImage: "thermometer.medium")
                    .font(.headline)
                Text(temperature)
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .accessibilityIdentifier("coolant-value")
                Text(reading == nil ? "Нет свежих данных · PID 0105" : "PID 0105")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.level != .normal {
                    Label(warningText(fresh: reading != nil), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(model.level == .critical ? Color.red : Color.orange)
                        .accessibilityIdentifier(model.level == .critical ? "overheat-critical" : "overheat-warning")
                }
            }
            .card()
            HStack(alignment: .top, spacing: 12) {
                metric("Обороты", value: rpm.map { "\(Int($0.value.rounded()))" } ?? "—", detail: "об/мин",
                       id: "rpm-value")
                metric("Напряжение", value: voltage.map { "\($0.value.formatted(.number.precision(.fractionLength(1)))) В" } ?? "—",
                       detail: voltage == nil ? "Нет данных" : (model.supplementary?.voltageSource == .adapter ? "Адаптер · ATRV" : "ECU · 0142"),
                       id: "voltage-value")
            }
            #if !CARGAUGE_BASIC
            if model.activityIsRunning || isActive {
                Button(model.activityIsRunning ? "Завершить Live Activity" : "Начать Live Activity") {
                    model.toggleActivity()
                }
                .buttonStyle(.bordered)
                .disabled(!model.activityIsRunning && reading == nil)
                .accessibilityIdentifier("live-activity-button")
            }
            #endif
            if let message = model.presentationMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func warningText(fresh: Bool) -> String {
        if !fresh { return "Последнее измерение было высоким · связь с ECU прервана или данные устарели" }
        return model.level == .critical ? "Критическая температура ОЖ" : "Высокая температура ОЖ"
    }

    private func metric(_ title: String, value: String, detail: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .accessibilityIdentifier(id)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var warmupChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("График прогрева").font(.headline)
            if model.history.count < 2 {
                Text("График появится после двух замеров.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(chartPoints, id: \.reading.timestamp) { point in
                        LineMark(x: .value("Время", point.reading.timestamp),
                                 y: .value("°C", point.reading.value),
                                 series: .value("Участок", point.segment))
                            .foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Время", point.reading.timestamp), y: .value("°C", point.reading.value))
                            .symbolSize(8)
                            .foregroundStyle(Color.accentColor)
                    }
                    RuleMark(y: .value("Порог предупреждения", 105))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.75))
                }
                .chartYAxisLabel("°C")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .frame(height: 155)
                .accessibilityIdentifier("warmup-chart")
            }
            Text("Пороги прототипа: 105 и 115 °C. Сверяйтесь со штатной индикацией автомобиля.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private struct ChartPoint {
        let reading: Reading
        let segment: Int
    }

    private var chartPoints: [ChartPoint] {
        var segment = 0
        var last: Date?
        return model.history.map { reading in
            if let last, reading.timestamp.timeIntervalSince(last) >= 5 { segment += 1 }
            last = reading.timestamp
            return ChartPoint(reading: reading, segment: segment)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.source == .simulator {
                LabeledContent("Источник данных") {
                    Text("Симулятор OBD-II").accessibilityIdentifier("simulator-source")
                }
                Picker("Сценарий", selection: Binding(get: { model.scenario }, set: { model.setScenario($0) })) {
                    Text("Прогрев").tag(SimulationScenario.warmup)
                    Text("Перегрев").tag(SimulationScenario.overheat)
                    Text("Напряжение через ATRV").tag(SimulationScenario.noVoltagePID)
                    Text("Обрыв связи").tag(SimulationScenario.disconnect)
                }
            } else {
                AdapterControls(ble: model.ble, isRunning: model.isRunning, onSelect: model.selectDevice(_:))
                Toggle("Автоподключение", isOn: $model.autoConnect)
                Button("Разрешить уведомления о температуре") {
                    Task { await model.requestWarningNotifications() }
                }
            }
            Button(model.isRunning ? "Остановить измерение" : "Начать измерение") {
                if model.isRunning { model.stop() } else { model.start() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(model.isRunning ? "stop-measurement" : "start-measurement")
        }
        .card()
    }
}

private struct AdapterControls: View {
    @ObservedObject var ble: BLETransport
    let isRunning: Bool
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ble.diagnostic).font(.subheadline).foregroundStyle(.secondary)
            if !isRunning {
                Button("Найти Vgate по Bluetooth") { ble.discover() }
                ForEach(ble.devices) { device in
                    Button {
                        onSelect(device.id)
                    } label: {
                        LabeledContent(device.name, value: "\(device.rssi) dBm")
                    }
                }
            }
        }
    }
}

private extension View {
    func card() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
