import CarGaugeCore
import Charts
import SwiftUI

struct DriveDashboardReadings: View {
    @ObservedObject var drive: DriveMonitor
    @Environment(\.gaugePalette) private var palette

    var body: some View {
        if !drive.supported.isEmpty {
            GaugeSection(title: "Телеметрия") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let now = DriveClock.now
                    let rate = drive.fuel?.validUntil.map { now <= $0 } == true ? drive.fuel : nil
                    let speed = drive.readings[.speed].flatMap { $0.isFresh(at: now, within: 3) ? $0.value : nil }
                    LabeledContent("Расход · расчёт", value: driveValue(rate?.litresPerHour, unit: "л/ч"))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Расход · расчёт, \(driveValue(rate?.litresPerHour, unit: "л/ч"))"))
                        .accessibilityIdentifier("live-fuel-rate")
                    LabeledContent("Расход в движении", value: driveValue(rate?.litresPer100km(speed: speed), unit: "л/100 км"))
                    Text("Speed Density · экспериментальная оценка")
                        .font(.caption).foregroundStyle(palette.muted)
                    if rate == nil {
                        Text(drive.targetProfileConfirmed
                             ? "Оценка доступна при свежих данных и штатном замкнутом контуре."
                             : "Ожидание совпадения карт PID с профилем G4FC.")
                            .font(.caption).foregroundStyle(palette.muted)
                    }
                    ForEach(drive.supported.filter { drive.visibleSignals.contains($0) }) { signal in
                        LabeledContent(signal.title, value: liveValue(signal, at: now))
                    }
                }
                if let storageError = drive.storageError {
                    Text("Запись истории недоступна. \(storageError)")
                        .font(.footnote).foregroundStyle(palette.warning)
                }
            }
            .monospacedDigit()
        }
    }

    private func liveValue(_ signal: DriveSignal, at time: Double) -> String {
        guard let reading = drive.readings[signal], reading.isFresh(at: time, within: signal.displayLifetime) else { return "—" }
        if signal == .fuelStatus, reading.bytes.count == 2 {
            let first = fuelSystemStatus(reading.bytes[0])
            let second = reading.bytes[1]
            return second == 0 ? first : "1 · \(first), 2 · \(fuelSystemStatus(second))"
        }
        if let value = reading.value { return driveValue(value, unit: signal.unit) }
        return reading.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    private func fuelSystemStatus(_ status: UInt8) -> String {
        switch status {
        case 1: "Условия замкнутого контура ещё не выполнены"
        case 2: "Замкнутый контур"
        case 4: "Открытый контур · режим движения"
        case 8, 16: "Ограниченный режим"
        default: "Неясный статус"
        }
    }

}

struct DriveHistorySection: View {
    @ObservedObject var drive: DriveMonitor
    @Environment(\.gaugePalette) private var palette
    @State private var trips: [RecordedTrip] = []
    @State private var selected: RecordedTrip?
    @State private var more = false
    @State private var size: Int64?
    @State private var message: String?
    @State private var calibration = false

    var body: some View {
        GaugeSection(title: "История поездок", headerID: "recorded-trips") {
            Text("Запись начинается после первого ответа двигателя. Время без подтверждённых оборотов отмечается отдельно.")
                .font(.footnote).foregroundStyle(palette.muted)
            if trips.isEmpty { Text("Здесь появятся сохранённые поездки.").font(.subheadline) }
            ForEach(trips) { trip in
                Button { selected = trip } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                            Text(trip.startedAt, format: .dateTime.day().month().hour().minute()).font(.headline)
                            Text("\(driveValue(trip.distanceKm, unit: "км")) · \(driveDuration(trip.observedEngineSeconds))")
                                .font(.caption).foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recorded-trip")
            }
            if more { Button("Показать раньше") { Task { await load(append: true) } }.buttonStyle(GaugeActionStyle()) }
            if let size {
                LabeledContent("Локальная база", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .accessibilityIdentifier("history-space")
            }
            if let message { Text(message).font(.footnote).foregroundStyle(palette.warning) }
            Button("Калибровка по заправкам") { calibration = true }
                .buttonStyle(GaugeActionStyle())
                .accessibilityIdentifier("fuel-calibration")
        }
        .task { await load(append: false) }
        .sheet(item: $selected) { DriveTripDetail(drive: drive, trip: $0) }
        .sheet(isPresented: $calibration) { DriveCalibrationView(drive: drive) }
    }

    private func load(append: Bool) async {
        do {
            let page = try await drive.archive.recentTrips(before: append ? trips.last?.id : nil, limit: 25)
            size = try await drive.archive.databaseSize()
            if append { trips += page } else { trips = page }
            more = page.count == 25
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct DriveTripDetail: View {
    let drive: DriveMonitor
    @State var trip: RecordedTrip
    var focusEventID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gaugePalette) private var palette
    @State private var plot: TripPlot?
    @State private var selection: Double?
    @State private var markers: [HistoryMarker] = []
    @State private var channels: Set<DriveSignal> = [.coolant, .rpm, .speed]
    @State private var message: String?

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть", action: { dismiss() }).buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Замеры поездки", subtitle: trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                .accessibilityIdentifier("trip-details")
            #if DEBUG
            if drive.isFixture { SourceIndicator(source: .simulator) }
            #endif
            metrics
            if !markers.isEmpty { timelineSection }
            if let plot {
                channelMenu
                if plot.gaps > 0 {
                    Text("Разрывов наблюдения: \(plot.gaps)").font(.footnote).foregroundStyle(palette.muted)
                }
                ForEach(DriveSignal.allCases.filter { channels.contains($0) }) { signal in
                    plotSection(signal.title, unit: signal.unit, points: plot.series[signal] ?? [], length: plot.seconds,
                                tolerance: min(3, signal.displayLifetime / 2))
                }
                plotSection("Расход · расчёт", unit: "л/ч", points: plot.fuel, length: plot.seconds, tolerance: 3)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(palette.warning) }
        }
        .task(id: channels) {
            do {
                repeat {
                    guard let snapshot = try await drive.archive.detail(tripID: trip.id, channels: channels) else { break }
                    plot = snapshot.plot
                    trip = snapshot.trip
                    markers = try await drive.archive.historyMarkers(trip: snapshot.trip.id)
                    if selection == nil, let focusEventID {
                        selection = markers.first { $0.id == focusEventID }?.elapsed
                    }
                    if snapshot.trip.finishReason != nil { break }
                    try await Task.sleep(for: .seconds(5))
                } while !Task.isCancelled
            } catch is CancellationError {
                // Dismissal and channel selection cancel the current reader.
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private var timelineSection: some View {
        GaugeSection(title: "События поездки") {
            ForEach(markers) { marker in
                Button { selection = marker.elapsed } label: {
                    Label(marker.title, systemImage: marker.kind == "servicing" ? "wrench" : "waveform.path.ecg")
                }
                .buttonStyle(GaugeActionStyle())
            }
        }
    }

    private var metrics: some View {
        GaugeSection(title: "За наблюдаемый период") {
            LabeledContent("Время между замерами", value: driveDuration(trip.elapsedSeconds))
            LabeledContent("Подтверждённая работа двигателя", value: driveDuration(trip.observedEngineSeconds))
            LabeledContent("Пробег по скорости ЭБУ", value: driveValue(trip.distanceKm, unit: "км"))
            LabeledContent("Максимальная скорость", value: driveValue(trip.peakSpeed, unit: "км/ч"))
            LabeledContent("Топливо · оценка", value: driveVolume(trip.litres))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Топливо, оценка, \(driveVolume(trip.litres))"))
                .accessibilityIdentifier("trip-fuel-volume")
            LabeledContent("Средний · совпадающее покрытие", value: driveValue(trip.averageLitresPer100km, unit: "л/100 км"))
            LabeledContent("Холостой ход", value: trip.distanceSeconds > 0 ? driveDuration(trip.idleSeconds) : "—")
            LabeledContent("На холостом ходу · оценка", value: driveVolume(trip.idleLitres))
            LabeledContent("Покрытие расчёта топлива", value: driveDuration(trip.fuelSeconds))
            LabeledContent("Покрытие расстояния", value: driveDuration(trip.distanceSeconds))
            if let start = trip.estimatedEngineStart {
                LabeledContent("Оценка запуска по 011F", value: start.formatted(date: .omitted, time: .standard))
                if let connectedAt = trip.connectedAt, start < connectedAt {
                    LabeledContent("Работа до BLE · оценка", value: driveDuration(connectedAt.timeIntervalSince(start)))
                }
            }
            Text("Телеметрия и топливо до начала записи неизвестны. Расход рассчитан методом Speed Density.")
                .font(.footnote).foregroundStyle(palette.muted)
        }
        .monospacedDigit()
    }

    private var channelMenu: some View {
        Menu("Графики параметров", systemImage: "chart.xyaxis.line") {
            ForEach(DriveSignal.allCases.filter { !$0.unit.isEmpty }) { signal in
                Button {
                    if !channels.insert(signal).inserted { channels.remove(signal) }
                } label: {
                    Label(signal.title, systemImage: channels.contains(signal) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityIdentifier("plot-channels")
    }

    private func plotSection(_ title: String, unit: String, points: [TripPlot.Point],
                             length: Double, tolerance: Double) -> some View {
        let reduced = reducedPlot(points)
        let singletons = Set(Dictionary(grouping: reduced, by: \.segment).compactMap { _, points in
            points.count == 1 ? points.first?.id : nil
        })
        let nearest = selection.flatMap { x in
            points.min(by: { abs($0.time - x) < abs($1.time - x) })
                .flatMap { abs($0.time - x) <= tolerance ? $0.value : nil }
        }
        return GaugeSection(title: title) {
            if points.isEmpty {
                Text("За этот период данных нет.").font(.footnote).foregroundStyle(palette.muted)
            } else {
                if let selection {
                    LabeledContent(driveDuration(selection), value: driveValue(nearest, unit: unit))
                        .monospacedDigit()
                }
                Chart {
                    ForEach(reduced) { point in
                        LineMark(x: .value("Секунды", point.time), y: .value(title, point.value),
                                 series: .value("Участок", point.segment))
                            .foregroundStyle(palette.accent)
                        if singletons.contains(point.id) {
                            PointMark(x: .value("Секунды", point.time), y: .value(title, point.value))
                                .foregroundStyle(palette.accent)
                        }
                    }
                    ForEach(markers) { marker in
                        RuleMark(x: .value("Событие", marker.elapsed))
                            .foregroundStyle(palette.warning.opacity(0.55))
                    }
                    if let selection {
                        RuleMark(x: .value("Выбранное время", selection)).foregroundStyle(palette.muted)
                    }
                }
                .chartXScale(domain: 0...max(length, 1))
                .chartXSelection(value: $selection)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { mark in
                        AxisGridLine()
                        AxisValueLabel {
                            if let time = mark.as(Double.self) { Text(driveDuration(time)) }
                        }
                    }
                }
                .frame(height: 138)
                .accessibilityLabel(title + (unit.isEmpty ? "" : ", " + unit))
            }
        }
    }

    private func reducedPlot(_ points: [TripPlot.Point]) -> [TripPlot.Point] {
        let step = max(1, points.count / 480)
        guard step > 1 else { return points }
        return points.enumerated().compactMap { index, point in
            if index == 0 || index == points.count - 1 || index % step == 0
                || point.segment != points[index - 1].segment || point.segment != points[index + 1].segment {
                return point
            }
            return nil
        }
    }
}

struct DriveSettingsSection: View {
    @ObservedObject var drive: DriveMonitor
    @State private var showsCalibration = false

    var body: some View {
        GaugeSection(title: "Показания автомобиля") {
            DisclosureGroup("Выбрать показания на приборах") {
                ForEach(DriveSignal.allCases.filter { ![.coolant, .rpm, .ecuVoltage, .adapterVoltage].contains($0) }) { signal in
                    Toggle(signal.title, isOn: Binding(get: { drive.visibleSignals.contains(signal) }, set: { enabled in
                        if enabled { drive.visibleSignals.insert(signal) } else { drive.visibleSignals.remove(signal) }
                    }))
                }
            }
            Button("Калибровка по заправкам") { showsCalibration = true }.buttonStyle(GaugeActionStyle())
        }
        .sheet(isPresented: $showsCalibration) { DriveCalibrationView(drive: drive) }
    }
}

struct DriveCalibrationView: View {
    @ObservedObject var drive: DriveMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gaugePalette) private var palette
    @State private var state: FuelCalibrationState?
    @State private var odometer = ""
    @State private var litres = ""
    @State private var message: String?
    @State private var confirmsRestart = false
    @State private var confirmsCoverage = false

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Калибровка расхода", subtitle: "Полный бак до и после интервала поездок.")
            #if DEBUG
            if drive.isFixture { SourceIndicator(source: .simulator) }
            #endif
            GaugeSection(title: "Заправка") {
                if let state {
                    LabeledContent("Множитель будущих оценок", value: driveValue(state.factor, unit: "×", precision: 3))
                    LabeledContent("Учтено интервалов", value: String(state.matchedFills))
                    if let initial = state.initialOdometer {
                        LabeledContent("Начальное показание", value: driveValue(initial, unit: "км"))
                    }
                }
                TextField("Одометр, км", text: $odometer).keyboardType(.decimalPad)
                if state?.initialOdometer != nil {
                    TextField("Долито до полного, л", text: $litres).keyboardType(.decimalPad)
                    Toggle("Я записал все работы двигателя между заправками", isOn: $confirmsCoverage)
                }
                Button(state?.initialOdometer == nil ? "Отметить полный бак" : "Учесть полную заправку") {
                    Task { await save(restart: false) }
                }
                .buttonStyle(GaugeActionStyle())
                .disabled(state?.initialOdometer != nil && !confirmsCoverage)
                if state?.initialOdometer != nil {
                    Button("Начать новый интервал") { confirmsRestart = true }.buttonStyle(GaugeActionStyle())
                }
                Text("Нужна запись почти всех поездок между заправками. Расчёт допускается при покрытии от 90% пробега и работы двигателя. Учитываются только законченные поездки. Ранее сохранённые значения сохраняют исходную калибровку.")
                    .font(.footnote).foregroundStyle(palette.muted)
                if let message { Text(message).font(.footnote) }
            }
        }
        .task {
            do { state = try await drive.archive.calibration() }
            catch { message = error.localizedDescription }
        }
        .confirmationDialog("Начать новый интервал?", isPresented: $confirmsRestart) {
            Button("Отметить полный бак") { Task { await save(restart: true) } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func save(restart: Bool) async {
        guard let km = Double(odometer.replacingOccurrences(of: ",", with: ".")) else {
            message = FuelCalibrationError.invalid.errorDescription
            return
        }
        do {
            let changed: FuelCalibrationState
            if restart {
                changed = try await drive.archive.restartCalibration(odometer: km)
            } else if state?.initialOdometer == nil {
                changed = try await drive.archive.startCalibration(odometer: km)
            } else {
                guard let actual = Double(litres.replacingOccurrences(of: ",", with: ".")) else {
                    message = FuelCalibrationError.invalid.errorDescription
                    return
                }
                changed = try await drive.archive.finishCalibration(odometer: km, litres: actual, attestsCoverage: confirmsCoverage)
            }
            state = changed
            drive.settingCalibration(changed)
            message = "Заправка сохранена."
            odometer = ""
            litres = ""
            confirmsCoverage = false
        } catch {
            message = error.localizedDescription
        }
    }
}

struct DriveDiagnosticHistory: View {
    @ObservedObject var drive: DriveMonitor
    @State private var events: [String] = []

    var body: some View {
        DisclosureGroup("Автоматические проверки двигателя") {
            if events.isEmpty { Text("Подтверждённых результатов пока нет.").font(.footnote) }
            ForEach(events.indices, id: \.self) { index in
                Text(events[index]).font(.footnote)
            }
        }
        .task(id: drive.automaticReport?.id) { events = (try? await drive.archive.recentEvents()) ?? [] }
    }
}

private func driveValue(_ value: Double?, unit: String, precision: Int = 1) -> String {
    guard let value, value.isFinite else { return "—" }
    let text = value.formatted(.number.precision(.fractionLength(0...precision)))
    return unit.isEmpty ? text : "\(text) \(unit)"
}

private func driveVolume(_ litres: Double?) -> String {
    guard let litres, litres.isFinite, litres >= 0 else { return "—" }
    if litres > 0 && litres < 0.001 { return "Менее 1 мл" }
    if litres > 0 && litres < 0.1 { return driveValue(litres * 1000, unit: "мл", precision: 0) }
    return driveValue(litres, unit: "л")
}

private func driveDuration(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.rounded()))
    if value < 60 { return "\(value) с" }
    if value < 3600 { return "\(value / 60) мин \(value % 60) с" }
    return "\(value / 3600) ч \((value % 3600) / 60) мин"
}
