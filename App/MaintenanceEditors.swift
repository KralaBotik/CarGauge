import CarGaugeCore
import SwiftUI

typealias MaintenanceCommit = @MainActor (MaintenanceChange) async throws -> Void

@MainActor
struct MaintenanceEditorForm<Content: View>: View {
    let title: String
    var identifier: String
    var saveIdentifier = "maintenance-save"
    let save: @MainActor () async throws -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gaugePalette) private var palette
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                content
                if let error {
                    Text(error).font(.footnote).foregroundStyle(palette.warning)
                        .accessibilityIdentifier("maintenance-editor-error")
                }
            }
            .accessibilityIdentifier(identifier)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard !saving else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await save()
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier(saveIdentifier)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct MaintenanceNumberField: View {
    let title: String
    @Binding var value: Double?
    var identifier: String? = nil
    @State private var text: String?

    var body: some View {
        TextField(title, text: Binding(get: {
            text ?? value.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) } ?? ""
        }, set: { input in
            text = input
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? nil : Double(trimmed.replacingOccurrences(of: ",", with: ".")) ?? .nan
        }))
        .keyboardType(.decimalPad)
        .accessibilityIdentifier(identifier ?? title)
    }
}

struct MaintenanceMoneyField: View {
    let title: String
    @Binding var value: Int64?

    var body: some View {
        MaintenanceNumberField(title: title, value: Binding(
            get: { value.map { Double($0) / 100 } },
            set: { amount in
                value = amount.map { major in Int64(exactly: (major * 100).rounded()) ?? -1 }
            }
        ))
    }
}

struct MaintenanceIntegerField: View {
    let title: String
    @Binding var value: Int?

    var body: some View {
        MaintenanceNumberField(title: title, value: Binding(
            get: { value.map(Double.init) },
            set: { number in value = number.map { Int(exactly: $0) ?? -1 } }
        ))
    }
}

struct MaintenanceBasisNumber: View {
    let title: String
    @Binding var value: MaintenanceValue<Double>
    var identifier: String? = nil
    var required = false

    var body: some View {
        Picker(title, selection: Binding(
            get: { required && value.certainty == .unknown ? .exact : value.certainty },
            set: { certainty in
                if certainty == .unknown { value = .init() }
                else { value.certainty = certainty }
            }
        )) {
            ForEach(MaintenanceCertainty.allCases.filter { !required || $0 != .unknown }) {
                Text($0.title).tag($0)
            }
        }
        if required || value.certainty != .unknown {
            MaintenanceNumberField(title: title, value: Binding(
                get: { value.value },
                set: { number in
                    value.value = number
                    if value.certainty == .unknown { value.certainty = .exact }
                }
            ), identifier: identifier)
        }
    }
}

struct MaintenanceBasisDate: View {
    let title: String
    @Binding var value: MaintenanceValue<Date>

    var body: some View {
        Picker(title, selection: Binding(get: { value.certainty }, set: { certainty in
            value = certainty == .unknown ? .init() : .init(value.value ?? .now, certainty: certainty)
        })) {
            ForEach(MaintenanceCertainty.allCases) { Text($0.title).tag($0) }
        }
        if value.certainty != .unknown {
            DatePicker(title, selection: Binding(get: { value.value ?? .now }, set: { value.value = $0 }),
                       in: ...Date.now, displayedComponents: .date)
        }
    }
}

@MainActor
struct MaintenanceOdometerEditor: View {
    @State private var draft: MaintenanceOdometer
    let commit: MaintenanceCommit

    init(reading: MaintenanceOdometer?, commit: @escaping MaintenanceCommit) {
        _draft = State(initialValue: reading ?? .init(odometer: .init()))
        self.commit = commit
    }

    var body: some View {
        MaintenanceEditorForm(title: "Одометр", identifier: "maintenance-odometer-editor",
                              saveIdentifier: "maintenance-save-odometer", save: { try await commit(.saveOdometer(draft)) }) {
            Section("Показания") {
                DatePicker("Когда записано", selection: $draft.date, in: ...Date.now)
                MaintenanceBasisNumber(title: "Пробег, км", value: $draft.odometer, identifier: "maintenance-odometer-value",
                                       required: true)
                MaintenanceBasisNumber(title: "Моточасы, ч", value: $draft.engineHours)
                Toggle("Корректировка одометра", isOn: $draft.correction)
                TextField("Комментарий", text: $draft.comment, axis: .vertical)
            }
            Section {
                Text("Укажите показание с приборной панели. Корректировка сохраняется отдельной отметкой.")
                    .font(.footnote)
            }
        }
    }
}

@MainActor
struct MaintenanceFillEditor: View {
    @State private var draft: MaintenanceFill
    @State private var volume: Double?
    let commit: MaintenanceCommit

    init(fill: MaintenanceFill?, commit: @escaping MaintenanceCommit) {
        _draft = State(initialValue: fill ?? .init(date: .init(.now), odometer: .init(),
                                                   litres: 0, fullTank: false))
        _volume = State(initialValue: fill?.litres)
        self.commit = commit
    }

    var body: some View {
        MaintenanceEditorForm(title: "Заправка", identifier: "maintenance-fill-editor",
                              saveIdentifier: "maintenance-save-fill", save: {
            guard let volume else { throw MaintenanceValidationError.invalidValue }
            draft.litres = volume
            try await commit(.saveFill(draft))
        }) {
            Section("Данные заправки") {
                MaintenanceBasisDate(title: "Дата", value: $draft.date)
                MaintenanceBasisNumber(title: "Пробег, км", value: $draft.odometer)
                MaintenanceNumberField(title: "Литры", value: $volume, identifier: "maintenance-fill-litres")
                TextField("Тип топлива", text: $draft.fuel)
                Toggle("Полный бак", isOn: $draft.fullTank)
            }
            Section("Расходы") {
                MaintenanceMoneyField(title: "Цена за литр, ₽", value: $draft.unitPriceMinor)
                MaintenanceMoneyField(title: "Стоимость по чеку, ₽", value: $draft.totalMinor)
                if draft.totalMinor == nil, let volume, let price = draft.unitPriceMinor,
                   let cents = Int64(exactly: (volume * Double(price)).rounded()), cents >= 0 {
                    LabeledContent("Расчётная стоимость", value: (Double(cents) / 100).formatted(.currency(code: "RUB")))
                }
                TextField("Комментарий", text: $draft.comment, axis: .vertical)
            }
        }
    }
}

@MainActor
struct MaintenanceRuleEditor: View {
    let components: [MaintenanceComponent]
    @State private var draft: MaintenanceRule
    let commit: MaintenanceCommit

    init(rule: MaintenanceRule?, selectedComponent: String?, components: [MaintenanceComponent],
         commit: @escaping MaintenanceCommit) {
        self.components = components
        let component = components.first { $0.id == selectedComponent } ?? components.first
        let action: MaintenanceOperation = component?.policy == .replacement ? .replacement : .inspection
        _draft = State(initialValue: rule ?? .init(componentID: component?.id ?? "", operation: action))
        self.commit = commit
    }

    var body: some View {
        MaintenanceEditorForm(title: "Интервал", identifier: "maintenance-rule-editor",
                              save: { try await commit(.saveRule(draft)) }) {
            Section("Планируемая работа") {
                Picker("Компонент", selection: $draft.componentID) {
                    ForEach(components) { Text($0.title).tag($0.id) }
                }
                Picker("Вид работы", selection: $draft.operation) {
                    ForEach(MaintenanceOperation.allCases.filter { $0 != .topUp }) { Text($0.title).tag($0) }
                }
                Picker("Условия", selection: $draft.regime) {
                    Text("Любые").tag(Optional<MaintenanceRegime>.none)
                    ForEach(MaintenanceRegime.allCases) { Text($0.title).tag(Optional($0)) }
                }
            }
            Section("Срок по первому из ограничений") {
                MaintenanceIntegerField(title: "Месяцы", value: $draft.months)
                MaintenanceNumberField(title: "Километры", value: $draft.distanceKm)
                MaintenanceNumberField(title: "Моточасы", value: $draft.engineHours)
            }
            Section(draft.source.kind.title) {
                TextField("Документ или причина выбора", text: $draft.source.citation, axis: .vertical)
                TextField("К каким условиям относится", text: $draft.source.applicability, axis: .vertical)
                if let reference = draft.source.reference { Link("Источник", destination: reference) }
            }
        }
    }
}

@MainActor
struct MaintenanceComponentEditor: View {
    @State private var component = MaintenanceComponent(title: "", category: .other, policy: .condition)
    let commit: MaintenanceCommit

    var body: some View {
        MaintenanceEditorForm(title: "Свой компонент", identifier: "maintenance-component-editor",
                              save: { try await commit(.saveComponent(component)) }) {
            Section("Каталог") {
                TextField("Название", text: $component.title)
                Picker("Группа", selection: $component.category) {
                    ForEach(MaintenanceCategory.allCases) { Text($0.title).tag($0) }
                }
                Picker("Стратегия обслуживания", selection: $component.policy) {
                    ForEach(MaintenancePolicy.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

@MainActor
struct MaintenanceSettingsEditor: View {
    @State private var draft: MaintenanceSettings
    let commit: MaintenanceCommit

    init(settings: MaintenanceSettings, commit: @escaping MaintenanceCommit) {
        _draft = State(initialValue: settings)
        self.commit = commit
    }

    var body: some View {
        MaintenanceEditorForm(title: "Регламент", identifier: "maintenance-settings-editor",
                              save: { try await commit(.settings(draft)) }) {
            Section("Условия эксплуатации") {
                Picker("Профиль", selection: $draft.regime) {
                    ForEach(MaintenanceRegime.allCases) { Text($0.title).tag($0) }
                }
                Text("Короткие поездки, длительный холостой ход, холод и дорожная соль могут повлиять на выбор профиля. Сверьте руководство своего рынка.")
                    .font(.footnote)
            }
            Section("Заблаговременность") {
                Toggle("Напоминания об обслуживании", isOn: $draft.notify)
                MaintenanceIntegerField(title: "Дней", value: Binding(
                    get: { draft.leadDays }, set: { draft.leadDays = $0 ?? 0 }))
                MaintenanceNumberField(title: "Километров", value: Binding(
                    get: { draft.leadKm }, set: { draft.leadKm = $0 ?? 0 }))
                MaintenanceNumberField(title: "Моточасов", value: Binding(
                    get: { draft.leadHours }, set: { draft.leadHours = $0 ?? 0 }))
            }
            Section("Источник интервалов") {
                Text("Для точного рынка этой Elantra заводской график пока не подтверждён. Интервалы пользователя доступны в каталоге.")
                    .font(.footnote)
            }
        }
    }
}
