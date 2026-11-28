import CarGaugeCore
import SwiftUI

@MainActor
struct MaintenanceView: View {
    let store: any MaintenanceStore
    var openFuelCalibration: (() -> Void)? = nil
    var useFuelInterval: (@MainActor (MaintenanceFuelInterval) async throws -> Void)? = nil
    var compareRecord: ((MaintenanceRecord, MaintenanceComponent) -> Void)? = nil

    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var ledger = MaintenanceLedger()
    @State private var counters = MaintenanceCounters()
    @State private var page = Page.overview
    @State private var editor: Editor?
    @State private var pendingDelete: Deletion?
    @State private var confirmsDeletion = false
    @State private var confirmsCalibration = false
    @State private var calibrationCandidate: MaintenanceFuelInterval?
    @State private var calibrationMessage: String?
    @State private var error: String?
    @State private var loaded = false

    enum Page: String, CaseIterable, Identifiable {
        case overview, journal, fills, catalog
        var id: Self { self }
        var title: String {
            switch self {
            case .overview: "Сроки"
            case .journal: "Журнал"
            case .fills: "Топливо"
            case .catalog: "Каталог"
            }
        }
    }

    private enum Editor: Identifiable {
        case record(MaintenanceRecord?), odometer(MaintenanceOdometer?), fill(MaintenanceFill?)
        case rule(MaintenanceRule?, String?), component, settings

        var id: String {
            switch self {
            case .record(let record): "work-" + (record?.id.uuidString ?? "new")
            case .odometer(let reading): "odo-" + (reading?.id.uuidString ?? "new")
            case .fill(let fill): "fill-" + (fill?.id.uuidString ?? "new")
            case .rule(let rule, let component): "rule-" + (rule?.id.uuidString ?? component ?? "new")
            case .component: "component"
            case .settings: "settings"
            }
        }
    }

    private enum Deletion {
        case record(UUID), odometer(UUID), fill(UUID), rule(UUID)
        var change: MaintenanceChange {
            switch self {
            case .record(let id): .deleteRecord(id)
            case .odometer(let id): .deleteOdometer(id)
            case .fill(let id): .deleteFill(id)
            case .rule(let id): .deleteRule(id)
            }
        }
    }

    var body: some View {
        GaugePage(spacing: GaugeSpacing.section) {
            GaugeHeading(title: "Обслуживание", subtitle: "Регламент, журнал работ и расходы")
            picker
            if let error {
                Text(error).font(.footnote).foregroundStyle(palette.warning)
                Button("Перечитать журнал") { Task { await reload() } }.buttonStyle(GaugeActionStyle())
            }
            if loaded {
                switch page {
                case .overview: overview
                case .journal: journal
                case .fills: fuel
                case .catalog: catalog
                }
            } else if error == nil {
                ProgressView("Загрузка журнала")
            }
        }
        .accessibilityIdentifier("maintenance-screen")
        .task { await reload() }
        .sheet(item: $editor) { item in
            switch item {
            case .record(let record):
                MaintenanceRecordEditor(record: record, components: ledger.components, commit: commit)
            case .odometer(let reading):
                MaintenanceOdometerEditor(reading: reading, commit: commit)
            case .fill(let fill):
                MaintenanceFillEditor(fill: fill, commit: commit)
            case .rule(let rule, let component):
                MaintenanceRuleEditor(rule: rule, selectedComponent: component, components: ledger.components, commit: commit)
            case .component:
                MaintenanceComponentEditor(commit: commit)
            case .settings:
                MaintenanceSettingsEditor(settings: ledger.settings, commit: commit)
            }
        }
        .confirmationDialog("Удалить запись?", isPresented: $confirmsDeletion, titleVisibility: .visible,
                            presenting: pendingDelete) { deletion in
            Button("Удалить", role: .destructive) {
                Task {
                    do { try await commit(deletion.change) }
                    catch { self.error = error.localizedDescription }
                }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Связанные вложения этой записи также будут удалены.")
        }
        .confirmationDialog("Учесть интервал в калибровке?", isPresented: $confirmsCalibration,
                            titleVisibility: .visible, presenting: calibrationCandidate) { interval in
            Button("Подтверждаю полную запись") {
                guard let useFuelInterval else { return }
                Task {
                    do {
                        try await useFuelInterval(interval)
                        calibrationMessage = "Интервал принят. Новая калибровка действует на будущие оценки."
                    } catch {
                        calibrationMessage = error.localizedDescription
                    }
                }
                calibrationCandidate = nil
            }
            Button("Отмена", role: .cancel) { calibrationCandidate = nil }
        } message: { _ in
            Text("Подтвердите, что внесены все заправки и между ними записана вся работа двигателя, включая стоянки и прогрев.")
        }
    }

    @ViewBuilder private var picker: some View {
        if typeSize.isAccessibilitySize {
            sectionPicker.pickerStyle(.menu)
        } else {
            sectionPicker.pickerStyle(.segmented)
        }
    }

    private var sectionPicker: some View {
        Picker("Раздел обслуживания", selection: $page) {
            ForEach(Page.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("maintenance-ledger-sections")
    }

    private func requestDeletion(_ deletion: Deletion) {
        pendingDelete = deletion
        confirmsDeletion = true
    }

    private var overview: some View {
        let statuses = MaintenanceDueEvaluator.statuses(ledger: ledger, current: counters)
        let pending = statuses.filter { $0.state.canRemind }
        let unknown = statuses.filter { $0.state == .unknownHistory }
        return Group {
            GaugeSection(title: "Пробег и моточасы", headerID: "maintenance-odometer") {
                LabeledContent("Последнее ручное показание", value: estimate(counters.odometerKm, unit: "км", certainty: counters.odometerCertainty))
                if let estimated = counters.estimatedOdometerKm {
                    LabeledContent("Оценка по записанным поездкам", value: "≈" + number(estimated, unit: "км"))
                }
                LabeledContent("Моточасы по записи владельца", value: estimate(counters.engineHours, unit: "ч", certainty: counters.engineHoursCertainty))
                if let hours = counters.observedEngineHours {
                    LabeledContent("Наблюдалось после отметки", value: number(hours, unit: "ч"))
                }
                Button("Записать одометр") { editor = .odometer(nil) }
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("maintenance-add-odometer")
                if !ledger.odometers.isEmpty {
                    DisclosureGroup("Показания и корректировки") {
                        ForEach(ledger.odometers.sorted(by: { $0.date > $1.date })) { reading in
                            itemRow(
                                title: number(reading.odometer.value, unit: "км") + (reading.correction ? " · корректировка" : ""),
                                detail: dateLabel(reading.date), edit: { editor = .odometer(reading) },
                                delete: { requestDeletion(.odometer(reading.id)) })
                        }
                    }
                }
                Text("Поездки без телефона не входят в оценку. Для расчёта сроков используется ручное показание.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }
            GaugeSection(title: "Ближайшие работы") {
                if pending.isEmpty {
                    Text("По настроенным интервалам и осмотрам срочных записей пока нет.")
                        .foregroundStyle(palette.muted)
                }
                ForEach(pending.prefix(12)) { entry in dueRow(entry) }
                if pending.count > 12 {
                    DisclosureGroup("Ещё \(pending.count - 12)") {
                        ForEach(pending.dropFirst(12)) { entry in dueRow(entry) }
                    }
                }
                if !unknown.isEmpty {
                    DisclosureGroup("История или срок неизвестны · \(unknown.count)") {
                        ForEach(unknown) { entry in dueRow(entry) }
                    }
                }
                Button("Регламент и напоминания") { editor = .settings }
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("maintenance-settings")
            }
        }
        .monospacedDigit()
    }

    private var journal: some View {
        GaugeSection(title: "Записи обслуживания", headerID: "maintenance-journal") {
            Button("Добавить обслуживание") { editor = .record(nil) }
                .buttonStyle(GaugeActionStyle(emphasized: true))
                .accessibilityIdentifier("maintenance-add-record")
            if ledger.records.isEmpty {
                Text("Добавьте известную работу, даже если дата или пробег сохранились приблизительно.")
                    .foregroundStyle(palette.muted)
            }
            ForEach(ledger.records.sorted(by: { $0.displayDate > $1.displayDate })) { record in
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    itemRow(title: recordTitle(record), detail: recordSubtitle(record),
                            edit: { editor = .record(record) }, delete: { requestDeletion(.record(record.id)) })
                    if let compareRecord, record.date.certainty == .exact,
                       let component = ledger.components.first(where: { component in
                           !component.comparableSignals.isEmpty && record.work.contains { $0.componentID == component.id }
                       }) {
                        Button("Показатели до и после") { compareRecord(record, component) }
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    GaugeRule()
                }
                .accessibilityIdentifier("maintenance-record")
            }
            if ledger.attachmentBytes > 0 {
                LabeledContent("Место вложений", value: ByteCountFormatter.string(
                    fromByteCount: Int64(ledger.attachmentBytes), countStyle: .file))
            }
        }
    }

    private var fuel: some View {
        let expenses = ledger.expenses
        return Group {
            GaugeSection(title: "Заправки", headerID: "maintenance-fills") {
                Button("Добавить заправку") { editor = .fill(nil) }
                    .buttonStyle(GaugeActionStyle(emphasized: true))
                    .accessibilityIdentifier("maintenance-add-fill")
                if let openFuelCalibration {
                    Button("Открыть калибровку расхода", action: openFuelCalibration).buttonStyle(GaugeActionStyle())
                }
                if ledger.fills.isEmpty {
                    Text("Сохраните объём, пробег и признак полного бака.").foregroundStyle(palette.muted)
                }
                ForEach(ledger.fills.sorted(by: { ($0.date.value ?? .distantPast) > ($1.date.value ?? .distantPast) })) { fill in
                    itemRow(title: number(fill.litres, unit: "л") + (fill.fullTank ? " · полный бак" : " · неполный бак"),
                            detail: [valueDate(fill.date), number(fill.odometer.value, unit: "км"), money(fill.knownCost)].joined(separator: " · "),
                            edit: { editor = .fill(fill) }, delete: { requestDeletion(.fill(fill.id)) })
                }
                let intervals = ledger.fuelIntervals
                if let interval = intervals.first {
                    fuelIntervalRow(interval)
                    if intervals.count > 1 {
                        DisclosureGroup("Другие полные интервалы") {
                            ForEach(intervals.dropFirst()) { item in fuelIntervalRow(item) }
                        }
                    }
                } else {
                    Text("Для сверки нужны два полных бака, точные даты, одометр и все заправки между ними.")
                        .font(.footnote).foregroundStyle(palette.muted)
                }
                if let calibrationMessage {
                    Text(calibrationMessage).font(.footnote).foregroundStyle(palette.muted)
                }
            }
            GaugeSection(title: "Внесённые расходы") {
                LabeledContent("Топливо", value: money(expenses.fuelMinor))
                LabeledContent("Обслуживание", value: money(expenses.maintenanceMinor))
                LabeledContent("Ремонт", value: money(expenses.repairMinor))
                LabeledContent("Всего известно", value: money(expenses.totalMinor))
                if let cost = expenses.knownCostPerKmMinor {
                    LabeledContent("По внесённым затратам", value: number(cost / 100, unit: "₽/км"))
                }
                if expenses.entriesWithUnknownCost > 0 {
                    Text("Часть стоимости не указана для \(expenses.entriesWithUnknownCost) работ или заправок.")
                        .font(.footnote).foregroundStyle(palette.muted)
                }
            }
        }
        .monospacedDigit()
    }

    private func fuelIntervalRow(_ interval: MaintenanceFuelInterval) -> some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.small) {
            LabeledContent("Между полными баками", value: number(interval.litresPer100km, unit: "л/100 км"))
            Text("\(valueDate(interval.start.date)) — \(valueDate(interval.end.date)) · \(number(interval.distanceKm, unit: "км"))")
                .font(.footnote).foregroundStyle(palette.muted)
            if useFuelInterval != nil {
                Button("Сверить с калибровкой") {
                    calibrationCandidate = interval
                    confirmsCalibration = true
                }
                .buttonStyle(GaugeActionStyle())
                .accessibilityIdentifier("maintenance-use-fill-interval")
            }
        }
    }

    private var catalog: some View {
        GaugeSection(title: "Компоненты", headerID: "maintenance-catalog") {
            Text("Обычные или тяжёлые условия выбирает владелец. Личный интервал можно задать для любой работы.")
                .font(.footnote).foregroundStyle(palette.muted)
            ForEach(MaintenanceCategory.allCases) { category in
                let components = ledger.components.filter { $0.category == category }
                DisclosureGroup(category.title) {
                    ForEach(components) { component in
                        VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                            Text(component.title).font(.headline)
                            Text(component.policy.title).font(.caption).foregroundStyle(palette.muted)
                            ForEach(ledger.rules.filter { $0.componentID == component.id }) { rule in
                                itemRow(title: rule.operation.title + " · " + rule.source.kind.title,
                                        detail: ruleLimits(rule),
                                        edit: { editor = .rule(rule, nil) }, delete: { requestDeletion(.rule(rule.id)) })
                            }
                            Button("Задать интервал") { editor = .rule(nil, component.id) }
                                .buttonStyle(GaugeActionStyle())
                            GaugeRule()
                        }
                    }
                }
            }
            Button("Добавить свой компонент") { editor = .component }
                .buttonStyle(GaugeActionStyle())
        }
    }

    private func dueRow(_ issue: MaintenanceDue) -> some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(issue.component.title).font(.headline)
            Text(issue.state.title).font(.subheadline)
                .foregroundStyle(issue.state.rank >= 3 ? palette.warning : palette.muted)
            if let rule = issue.rule {
                Text(rule.source.kind.title + " · " + rule.operation.title)
                    .font(.caption).foregroundStyle(palette.muted)
            }
            let limits = [issue.dueDate.map(dateLabel),
                          issue.dueKm.map { number($0, unit: "км") },
                          issue.dueHours.map { number($0, unit: "ч") }].compactMap { $0 }
            if !limits.isEmpty {
                Text((issue.approximate ? "Ориентир · " : "") + limits.joined(separator: " · "))
                    .font(.caption)
            }
        }
    }

    private func itemRow(title: String, detail: String, edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: GaugeSpacing.medium) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                    Text(title).font(.headline).foregroundStyle(palette.text)
                    Text(detail).font(.caption).foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu("Действия", systemImage: "ellipsis") {
                Button("Редактировать", action: edit)
                Button("Удалить", role: .destructive, action: delete)
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private func recordTitle(_ record: MaintenanceRecord) -> String {
        let names = record.work.map { job in ledger.components.first { $0.id == job.componentID }?.title ?? job.componentID }
        return names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " и ещё \(names.count - 2)" : "")
    }

    private func recordSubtitle(_ record: MaintenanceRecord) -> String {
        let jobs = record.work.map { $0.operation.title }
        return [valueDate(record.date), jobs.prefix(2).joined(separator: ", "), number(record.odometer.value, unit: "км")]
            .joined(separator: " · ")
    }

    private func ruleLimits(_ rule: MaintenanceRule) -> String {
        [rule.months.map { "\($0) мес." }, rule.distanceKm.map { number($0, unit: "км") },
         rule.engineHours.map { number($0, unit: "ч") }, rule.regime?.title].compactMap { $0 }.joined(separator: " · ")
    }

    private func valueDate(_ value: MaintenanceValue<Date>) -> String {
        guard let date = value.value else { return "Дата неизвестна" }
        return (value.certainty == .approximate ? "≈ " : "") + dateLabel(date)
    }

    private func dateLabel(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    private func number(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)"
    }

    private func money(_ value: Int64?) -> String { number(value.map { Double($0) / 100 }, unit: "₽") }

    private func estimate(_ value: Double?, unit: String, certainty: MaintenanceCertainty) -> String {
        (certainty == .approximate ? "≈ " : "") + number(value, unit: unit)
    }

    private func reload() async {
        do {
            ledger = try await store.readMaintenance()
            loaded = true
            await refreshUsage()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commit(_ change: MaintenanceChange) async throws {
        ledger = try await store.applyMaintenance(change)
        await refreshUsage()
    }

    private func refreshUsage() async {
        let anchor = ledger.latestOdometer?.date ?? .distantPast
        counters = ledger.odometerCounters()
        do {
            let usage = try await store.observedMaintenanceUsage(after: anchor)
            guard (ledger.latestOdometer?.date ?? .distantPast) == anchor else { return }
            counters = ledger.odometerCounters(observed: usage)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
