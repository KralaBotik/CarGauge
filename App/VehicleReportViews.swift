import CarGaugeCore
import SwiftUI

struct VehicleReportSheet: View {
    let archive: TelemetryArchive
    let initialScope: VehicleReportScope
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gaugePalette) private var palette
    @State private var scope: VehicleReportScope?
    @State private var includePrivate = false
    @State private var shareURL: URL?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmsBackup = false

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Поделиться отчётом", subtitle: "Файл формируется на iPhone.")
                .accessibilityIdentifier("report-export-screen")
            GaugeSection(title: "Отчёт") {
                Picker("Данные", selection: $scope) {
                    Text(label(initialScope)).tag(nil as VehicleReportScope?)
                    ForEach(otherScopes, id: \.self) { item in Text(label(item)).tag(Optional(item)) }
                }
                .pickerStyle(.menu)
                Toggle("Добавить личные заметки и исходные ответы", isOn: $includePrivate)
                Text("По умолчанию скрыты пользовательские названия и заметки. В отчёт входят значения и даты. Фото и чеки доступны в резервной копии.")
                    .font(.footnote).foregroundStyle(palette.muted)
                ForEach(formats, id: \.self) { format in
                    Button(format.title) { Task { await prepare(format) } }.buttonStyle(GaugeActionStyle())
                        .disabled(busy)
                        .accessibilityIdentifier("prepare-report-\(format.rawValue)")
                }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Поделиться файлом", systemImage: "square.and.arrow.up") }
                        .buttonStyle(GaugeActionStyle())
                        .accessibilityIdentifier("share-report-file")
                }
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(palette.warning) }
            }
            GaugeSection(title: "Резервная копия") {
                Button("Создать копию SQLite") { confirmsBackup = true }
                    .buttonStyle(GaugeActionStyle())
                    .disabled(busy)
                Text("Полная копия включает частные записи, фотографии и чеки.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }
        }
        .onChange(of: scope) { _, _ in shareURL = nil }
        .onChange(of: includePrivate) { _, _ in shareURL = nil }
        .confirmationDialog("Сохранить полную копию с личными данными?", isPresented: $confirmsBackup) {
            Button("Создать копию") { Task { await backup() } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var formats: [VehicleReportFormat] {
        (scope ?? initialScope) == .servicing || (scope ?? initialScope) == .diagnostics ? [.json, .txt] : [.json, .csv, .txt]
    }

    private var otherScopes: [VehicleReportScope] {
        let common: [VehicleReportScope] = [.trip(nil), .survey, .diagnostics, .servicing]
        return common.filter { $0 != initialScope }
    }

    private func label(_ scope: VehicleReportScope) -> String {
        switch scope {
        case .trip(let id): id == nil ? "Последняя поездка" : "Выбранная поездка"
        case .problem: "Выбранная проблема"
        case .survey: "Последнее обследование"
        case .diagnostics: "Диагностическая история"
        case .servicing: "Обслуживание"
        }
    }

    private func directory() throws -> URL {
        let destination = URL.temporaryDirectory.appending(path: "CarGauge-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private func prepare(_ format: VehicleReportFormat) async {
        busy = true
        shareURL = nil
        message = nil
        defer { busy = false }
        let chosenScope = scope ?? initialScope
        let privacy = includePrivate
        do {
            let data = try await archive.vehicleReport(scope: chosenScope, format: format, includePrivate: privacy)
            let url = try directory().appending(path: "CarGauge.\(format.rawValue)")
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if chosenScope == (scope ?? initialScope), privacy == includePrivate { shareURL = url }
        } catch { message = error.localizedDescription }
    }

    private func backup() async {
        busy = true
        shareURL = nil
        message = nil
        defer { busy = false }
        do {
            let url = try directory().appending(path: "CarGauge-backup.sqlite3")
            try await archive.makeBackup(at: url)
            shareURL = url
        } catch { message = error.localizedDescription }
    }
}

struct ServicingComparisonRequest: Identifiable {
    let record: MaintenanceRecord
    let component: MaintenanceComponent
    var id: UUID { record.id }
}

struct ServicingComparisonSheet: View {
    let drive: DriveMonitor
    let request: ServicingComparisonRequest
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [VehicleComparison] = []
    @State private var selected: RecordedTrip?
    @State private var error: String?

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "До и после обслуживания", subtitle: request.component.title)
                .accessibilityIdentifier("service-comparison")
            Text("Сравнение использует записанные поездки рядом с работой. Требуются прогретый холостой ход и сопоставимые температура воздуха и нагрузка.")
            if rows.isEmpty {
                Text(error ?? "Сопоставимых данных пока недостаточно.").font(.subheadline)
            }
            ForEach(rows) { result in
                GaugeSection(title: result.signal.title) {
                    Text(result.context).font(.footnote)
                    LabeledContent("До · \(result.beforeTrips) поездки", value: amount(result.before, unit: result.signal.unit))
                    LabeledContent("После · \(result.afterTrips) поездки", value: amount(result.after, unit: result.signal.unit))
                    if let before = result.beforeTripID {
                        Button("График до работы") { Task { selected = try? await drive.archive.trip(id: before) } }.buttonStyle(GaugeActionStyle())
                    }
                    if let after = result.afterTripID {
                        Button("График после работы") { Task { selected = try? await drive.archive.trip(id: after) } }.buttonStyle(GaugeActionStyle())
                    }
                }
            }
            Text("Изменение наблюдений само по себе не доказывает влияние ремонта.").font(.footnote)
        }
        .task {
            guard let date = request.record.date.value, request.record.date.certainty == .exact else { return }
            do { rows = try await drive.archive.compareServicing(at: date, signals: request.component.comparableSignals) }
            catch { self.error = error.localizedDescription }
        }
        .sheet(item: $selected) { DriveTripDetail(drive: drive, trip: $0) }
    }
}

struct FuelComparisonSheet: View {
    let drive: DriveMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var result: FuelTripComparison?
    @State private var error: String?

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Расход по сопоставимым поездкам",
                         subtitle: "Одинаковая калибровка, близкие скорость и температура воздуха.")
            if let result {
                GaugeSection(title: "Две наблюдавшиеся поездки") {
                    LabeledContent(result.older.startedAt.formatted(date: .abbreviated, time: .shortened),
                                   value: amount(result.older.averageLitresPer100km, unit: "л/100 км"))
                    LabeledContent(result.newer.startedAt.formatted(date: .abbreviated, time: .shortened),
                                   value: amount(result.newer.averageLitresPer100km, unit: "л/100 км"))
                    LabeledContent("Разница средней скорости", value: amount(result.meanSpeedDifference, unit: "км/ч"))
                }
            } else { Text(error ?? "Сопоставимые поездки с достаточным покрытием пока не найдены.") }
            Text("Оценка расхода остаётся экспериментальной. Сравнение используется как наблюдение.").font(.footnote)
        }
        .task {
            do { result = try await drive.archive.comparableFuelTrips() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private func amount(_ value: Double?, unit: String) -> String {
    value.map { $0.formatted(.number.precision(.fractionLength(0...2))) + " " + unit } ?? "—"
}
