import CarGaugeCore
import SwiftUI

struct VehicleQuickStatus: View {
    @ObservedObject var health: VehicleHealthMonitor
    @ObservedObject var service: VehicleServicePortal
    let openDiagnosis: () -> Void
    let openService: () -> Void

    var body: some View {
        if health.update != nil || !health.openIssues.isEmpty || service.next != nil {
            GaugeSection(title: "Автомобиль") {
                Button(action: openDiagnosis) {
                    VStack(alignment: .leading) {
                        Text("Диагностика").font(.headline)
                        Text(diagnosticSummary).font(.caption)
                    }
                }.buttonStyle(GaugeActionStyle())
                Button(action: openService) {
                    VStack(alignment: .leading) {
                        Text("Обслуживание").font(.headline)
                        Text(service.next.map { "\($0.component.title) · \($0.state.title)" } ?? "Добавьте пробег и историю работ")
                            .font(.caption)
                    }
                }.buttonStyle(GaugeActionStyle())
            }
        }
    }

    private var diagnosticSummary: String {
        if let first = health.openIssues.first {
            return health.rules.first { $0.id == first.ruleID }?.title ?? first.ruleID
        }
        return health.update.map { "Наблюдение · \($0.regime.title)" } ?? "Ожидаются данные"
    }
}

struct VehicleHealthSection: View {
    let drive: DriveMonitor
    @ObservedObject var health: VehicleHealthMonitor
    let requestNotificationPermission: () -> Void
    @State private var findings: [DTCFinding] = []
    @State private var events: [MonitoringEvent] = []
    @State private var latest: DiagnosticReport?
    @State private var route: HealthRoute?
    @State private var message: String?
    @Environment(\.gaugePalette) private var palette

    var body: some View {
        GaugeSection(title: "Состояние автомобиля", headerID: "monitoring-screen") {
            if let latest {
                LabeledContent("Последняя проверка", value: latest.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(scanSummary(latest)).font(.footnote).foregroundStyle(palette.muted)
            } else {
                Text("Сводка появится после автоматического или ручного чтения ЭБУ.").font(.subheadline)
            }
            LabeledContent("Условия", value: health.update?.regime.title ?? "Свежих данных нет")
            if health.openIssues.isEmpty {
                Text("Сохранённых открытых проблем нет. Результат относится к выполненным проверкам.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }
            ForEach(health.openIssues) { issue in eventRow(issue) }
            Button { route = .export(.diagnostics) } label: {
                Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(GaugeActionStyle())
            .accessibilityIdentifier("vehicle-report")
            if let message = message ?? health.errorMessage { Text(message).font(.footnote).foregroundStyle(palette.warning) }
        }
        GaugeSection(title: "Коды ЭБУ", headerID: "dtc-history") {
            if findings.isEmpty { Text("Коды пока не записаны.").font(.subheadline) }
            ForEach(findings) { item in
                Button { route = .code(item) } label: {
                    VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                        Text(item.code + " · " + item.status.title).font(.headline.monospacedDigit())
                        Text(DTCCatalog.lookup(item.code)?.title ?? "Расшифровка для кода не подтверждена")
                            .font(.subheadline)
                        if item.notReportedAt != nil {
                            Text("В последующем сопоставимом ответе код не сообщён.")
                                .font(.caption).foregroundStyle(palette.muted)
                        }
                    }
                }.buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("dtc-finding")
            }
        }
        GaugeSection(title: "Правила и индивидуальная статистика") {
            ForEach(health.rules) { rule in
                Button { route = .rule(rule) } label: {
                    LabeledContent(rule.title, value: ruleState(rule))
                }
                .buttonStyle(GaugeActionStyle())
                .accessibilityIdentifier("monitoring-rule-" + rule.id)
            }
            Button("Индивидуальные нормы") { route = .baseline }
                .buttonStyle(GaugeActionStyle())
                .accessibilityIdentifier("vehicle-baseline")
            Button("Сопоставимые поездки") { route = .fuel }
                .buttonStyle(GaugeActionStyle())
        }
        GaugeSection(title: "История срабатываний") {
            if events.isEmpty { Text("События правил пока не записаны.").font(.subheadline) }
            ForEach(events) { event in eventRow(event) }
        }
        GaugeSection(title: "Напряжение и уведомления") {
            Button("Сверить ATRV с мультиметром") { route = .voltage }.buttonStyle(GaugeActionStyle())
            Toggle("Сообщать о диагностических проблемах", isOn: $health.notifyDiagnostics)
                .onChange(of: health.notifyDiagnostics) { _, enabled in if enabled { requestNotificationPermission() } }
            if health.notifyDiagnostics {
                Toggle("Только критические уведомления мониторинга", isOn: $health.criticalOnly)
            }
            Text("Уведомления мониторинга требуют работающего соединения и разрешения iOS.")
                .font(.footnote).foregroundStyle(palette.muted)
        }
        .task { await health.prepare(); await load() }
        .onChange(of: drive.automaticReport?.id) { _, _ in Task { await load() } }
        .onChange(of: health.openIssues.map(\.id)) { _, _ in Task { await load() } }
        .sheet(item: $route) { item in
            switch item {
            case .rule(let rule): HealthRuleSheet(health: health, rule: rule)
            case .code(let finding): DTCFindingSheet(drive: drive, finding: finding)
            case .issue(let event): HealthProblemSheet(drive: drive, event: event)
            case .voltage: AdapterVoltageSheet(drive: drive, health: health)
            case .baseline: VehicleBaselineSheet(health: health)
            case .fuel: FuelComparisonSheet(drive: drive)
            case .export(let scope): VehicleReportSheet(archive: drive.archive, initialScope: scope)
            }
        }
    }

    private func ruleState(_ rule: MonitoringRule) -> String {
        guard health.enabled(rule) else { return "Выключено" }
        return health.update?.results.first { $0.ruleID == rule.id }?.state.title ?? "Ожидаются данные"
    }

    private func eventRow(_ item: MonitoringEvent) -> some View {
        let title = health.rules.first { $0.id == item.ruleID }?.title ?? item.ruleID
        return Button { route = .issue(item) } label: {
            VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                Text(title).font(.headline)
                Text("\(item.kind == .recovery ? "Восстановление" : item.severity.title) · \(item.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(palette.muted)
            }
        }.buttonStyle(GaugeActionStyle())
    }

    private func scanSummary(_ report: DiagnosticReport) -> String {
        DiagnosticCodeStatus.allCases.map { status in
            let group = report.codes.first { $0.status == status }
            let count = group.map { Set($0.replyGroups.flatMap { $0 }).count }
            return "\(status.title) · " + (count.map { String($0) } ?? "нет результата")
        }.joined(separator: "\n")
    }

    private func load() async {
        do {
            findings = try await drive.archive.dtcFindings()
            latest = try await drive.archive.lastSurvey()
            events = try await drive.archive.monitoringEvents()
            message = nil
        } catch { message = error.localizedDescription }
    }
}

private enum HealthRoute: Identifiable {
    case rule(MonitoringRule), code(DTCFinding), issue(MonitoringEvent), voltage, baseline, fuel, export(VehicleReportScope)
    var id: String {
        switch self {
        case .rule(let value): value.key
        case .code(let value): value.id
        case .issue(let value): value.id.uuidString
        case .voltage: "voltage"
        case .baseline: "baseline"
        case .fuel: "fuel"
        case .export: "export"
        }
    }
}

private struct HealthRuleSheet: View {
    @ObservedObject var health: VehicleHealthMonitor
    let rule: MonitoringRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: rule.title, subtitle: "\(rule.origin.title) · версия \(rule.version)")
                .accessibilityIdentifier("monitoring-rule-detail")
            GaugeSection(title: "Условия") {
                Toggle("Оценивать правило", isOn: Binding(get: { health.enabled(rule) }, set: { value in
                    Task { await health.setEnabled(value, rule: rule) }
                }))
                LabeledContent("Серьёзность", value: rule.severity.title)
                Text(rule.applicability)
                Text(rule.rationale)
                Text(rule.limitations).font(.footnote)
                ForEach(rule.possibleCauses, id: \.self) { Text($0).font(.subheadline) }
                if let source = URL(string: rule.sourceURL), source.scheme == "https" {
                    Link("Источник правила", destination: source)
                }
            }
            if let result = health.update?.results.first(where: { $0.ruleID == rule.id }) {
                GaugeSection(title: result.state.title) {
                    ForEach(result.evidence) { item in
                        LabeledContent(item.title, value: "\(item.value.formatted(.number.precision(.fractionLength(0...2)))) \(item.unit)")
                    }
                    if !result.relatedDTCs.isEmpty { Text(result.relatedDTCs.joined(separator: ", ")) }
                }
            }
        }
    }
}

private struct HealthProblemSheet: View {
    let drive: DriveMonitor
    let event: MonitoringEvent
    @Environment(\.dismiss) private var dismiss
    @State private var trip: RecordedTrip?
    @State private var transitions: [MonitoringEvent] = []
    @State private var showsExport = false

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            let rule = MonitoringProfile.g4fc.rules.first { $0.id == event.ruleID && $0.version == event.ruleVersion }
            GaugeHeading(title: rule?.title ?? event.ruleID, subtitle: "\(event.severity.title) · \(event.regime.title)")
            GaugeSection(title: "Доказательства и контекст") {
                Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                if let duration = event.duration {
                    LabeledContent("Подтверждённая длительность", value: "\(Int(duration)) с")
                }
                ForEach(event.evidence) { item in
                    LabeledContent(item.title, value: "\(item.value.formatted(.number.precision(.fractionLength(0...2)))) \(item.unit)")
                }
                if !event.relatedDTCs.isEmpty { LabeledContent("Связанные DTC", value: event.relatedDTCs.joined(separator: ", ")) }
                if let rule { Text(rule.limitations).font(.footnote) }
                ForEach(transitions) { transition in
                    Text("\(transition.kind == .recovery ? "Восстановление" : "Проблема") · \(transition.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if let id = event.tripID {
                Button("Открыть графики поездки") { Task { trip = try? await drive.archive.trip(id: id) } }
                    .buttonStyle(GaugeActionStyle())
            }
            Button("Поделиться отчётом") { showsExport = true }.buttonStyle(GaugeActionStyle())
        }
        .task { transitions = (try? await drive.archive.monitoringEvents(issue: event.issueID)) ?? [] }
        .sheet(item: $trip) { DriveTripDetail(drive: drive, trip: $0, focusEventID: event.id.uuidString) }
        .sheet(isPresented: $showsExport) { VehicleReportSheet(archive: drive.archive, initialScope: .problem(event.issueID)) }
    }
}

private struct DTCFindingSheet: View {
    let drive: DriveMonitor
    let finding: DTCFinding
    @Environment(\.dismiss) private var dismiss
    @State private var sightings: [DTCHistoryEntry] = []
    @State private var freeze: DiagnosticReport?
    @State private var selectedTrip: RecordedTrip?

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: finding.code, subtitle: finding.status.title).accessibilityIdentifier("dtc-finding-detail")
            if let description = DTCCatalog.lookup(finding.code) {
                GaugeSection(title: description.title) {
                    Text(description.urgency.title)
                    ForEach(description.causes, id: \.self) { Text($0).font(.subheadline) }
                    Text(description.recommendation)
                    Text(description.limits).font(.footnote)
                    if let reference = URL(string: description.source), reference.scheme == "https" {
                        Link("Источник расшифровки", destination: reference)
                    }
                }
            }
            GaugeSection(title: "Наблюдения") {
                LabeledContent("Первый ответ с кодом", value: finding.firstSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Последний ответ с кодом", value: finding.lastSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Появлений в ответах", value: String(finding.appearances))
                if finding.notReportedAt != nil {
                    Text("Последующий сопоставимый ответ не содержит код. Состояние системы требует отдельной проверки.")
                        .font(.footnote)
                }
                ForEach(sightings.prefix(30), id: \.scan) { entry in
                    Button {
                        Task {
                            let candidate = try? await drive.archive.recordedSurvey(entry.scan)
                            freeze = candidate?.freezeCauses == [finding.code] ? candidate : nil
                        }
                    } label: {
                        LabeledContent(entry.timestamp.formatted(date: .abbreviated, time: .shortened),
                                       value: historyTitle(entry.kind))
                    }
                    .buttonStyle(GaugeActionStyle())
                }
                if let freeze {
                    Text("Freeze Frame совпал по коду причины. Физический ответчик не идентифицирован.").font(.footnote)
                    ForEach(Array(freeze.measurements.filter { $0.freezeFrame != nil }.enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.sensor.name, value: item.value.map { "\($0) \(item.sensor.unit)" } ?? "Неизвестно")
                    }
                }
                if let id = finding.lastTrip {
                    Button("Связанные графики") { Task { selectedTrip = try? await drive.archive.trip(id: id) } }
                        .buttonStyle(GaugeActionStyle())
                }
            }
        }
        .task { sightings = ((try? await drive.archive.dtcHistory(code: finding.code)) ?? []).filter { $0.status == finding.status } }
        .sheet(item: $selectedTrip) { DriveTripDetail(drive: drive, trip: $0) }
    }

    private func historyTitle(_ kind: String) -> String {
        switch kind {
        case "first_seen": "Первый ответ"
        case "reappeared": "Код снова получен"
        case "not_reported": "В ответе отсутствует"
        default: "Получен"
        }
    }
}

private struct VehicleBaselineSheet: View {
    @ObservedObject var health: VehicleHealthMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Индивидуальная статистика", subtitle: "Однородные режимы и подтверждённые наблюдения.")
                .accessibilityIdentifier("baseline-screen")
            let observations = health.update?.baseline ?? health.savedBaselines
            if observations.isEmpty { Text("Собираем сравнимые данные по нескольким поездкам.") }
            ForEach(observations) { observation in
                GaugeSection(title: observation.signal.title) {
                    Text(observation.regime.title)
                    Text("Поездок: \(observation.tripCount), отсчётов: \(observation.sampleCount)").font(.footnote)
                    if let median = observation.median {
                        LabeledContent("Медиана", value: median.formatted(.number.precision(.fractionLength(0...2))))
                    } else {
                        Text("Данных для сравнения пока недостаточно.").font(.footnote)
                    }
                }
            }
        }
    }
}

private struct AdapterVoltageSheet: View {
    let drive: DriveMonitor
    @ObservedObject var health: VehicleHealthMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var adapter = ""
    @State private var meter = ""

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            Button("Закрыть") { dismiss() }.buttonStyle(GaugeActionStyle())
            GaugeHeading(title: "Сверка напряжения", subtitle: "Сопоставьте одновременные замеры при одинаковой нагрузке.")
                .accessibilityIdentifier("voltage-reference")
            GaugeSection(title: "Показания") {
                Text("ATRV сообщает напряжение на адаптере. Сохранённая поправка относится к указанному измерению и условиям проверки.")
                    .font(.footnote)
                TextField("На адаптере, В", text: $adapter).keyboardType(.decimalPad)
                TextField("На мультиметре, В", text: $meter).keyboardType(.decimalPad)
                Button("Сохранить сверку") {
                    if let a = parse(adapter), let m = parse(meter) {
                        Task { await health.setVoltage(adapter: a, meter: m) }
                    }
                }
                .buttonStyle(GaugeActionStyle()).disabled(parse(adapter) == nil || parse(meter) == nil)
                if let reference = health.voltageReference {
                    LabeledContent("Поправка", value: "\(reference.offset.formatted(.number.precision(.fractionLength(0...2)))) В")
                    Button("Сбросить поправку") { Task { await health.clearVoltageReference() } }.buttonStyle(GaugeActionStyle())
                }
            }
            if let error = health.errorMessage { Text(error).font(.footnote) }
        }
        .task {
            if let reading = drive.readings[.adapterVoltage], reading.isFresh(at: DriveClock.now, within: 5), let value = reading.value {
                adapter = String(value)
            }
        }
    }

    private func parse(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
}
