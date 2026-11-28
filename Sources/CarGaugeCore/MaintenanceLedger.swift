import Foundation

public protocol MaintenanceStore: Sendable {
    func readMaintenance() async throws -> MaintenanceLedger
    func applyMaintenance(_ change: MaintenanceChange) async throws -> MaintenanceLedger
    func observedMaintenanceUsage(after date: Date) async throws -> MaintenanceUsage
}

extension MaintenanceStore {
    public func observedMaintenanceUsage(after date: Date) async throws -> MaintenanceUsage { .init() }
}

public struct MaintenanceUsage: Codable, Sendable {
    public var distanceKm: Double?
    public var engineHours: Double?

    public init(distanceKm: Double? = nil, engineHours: Double? = nil) {
        self.distanceKm = distanceKm
        self.engineHours = engineHours
    }
}

public enum MaintenanceRegime: String, Codable, Sendable, CaseIterable, Identifiable {
    case normal, severe
    public var id: Self { self }
    public var title: String { self == .normal ? "Обычные" : "Тяжёлые" }
}

public struct MaintenanceSettings: Codable, Sendable {
    public var regime: MaintenanceRegime
    public var notify: Bool
    public var leadDays: Int
    public var leadKm: Double
    public var leadHours: Double

    public init(regime: MaintenanceRegime = .normal, notify: Bool = false,
                leadDays: Int = 21, leadKm: Double = 500, leadHours: Double = 15) {
        self.regime = regime
        self.notify = notify
        self.leadDays = leadDays
        self.leadKm = leadKm
        self.leadHours = leadHours
    }
}

public struct MaintenanceRuleSource: Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case owner, manufacturer
        public var id: Self { self }
        public var title: String { self == .manufacturer ? "Руководство производителя" : "Интервал владельца" }
    }

    public var kind: Kind
    public var citation: String
    public var applicability: String
    public var reference: URL?

    public init(kind: Kind = .owner, citation: String = "", applicability: String = "", reference: URL? = nil) {
        self.kind = kind
        self.citation = citation
        self.applicability = applicability
        self.reference = reference
    }
}

public struct MaintenanceRule: Codable, Sendable, Identifiable {
    public var id: UUID
    public var componentID: String
    public var operation: MaintenanceOperation
    public var regime: MaintenanceRegime?
    public var months: Int?
    public var distanceKm: Double?
    public var engineHours: Double?
    public var source: MaintenanceRuleSource

    public init(id: UUID = UUID(), componentID: String, operation: MaintenanceOperation, regime: MaintenanceRegime? = nil,
                months: Int? = nil, distanceKm: Double? = nil, engineHours: Double? = nil,
                source: MaintenanceRuleSource = .init()) {
        self.id = id
        self.componentID = componentID
        self.operation = operation
        self.regime = regime
        self.months = months
        self.distanceKm = distanceKm
        self.engineHours = engineHours
        self.source = source
    }
}

public enum MaintenanceChange: Sendable {
    case saveRecord(MaintenanceRecord), deleteRecord(UUID)
    case saveOdometer(MaintenanceOdometer), deleteOdometer(UUID)
    case saveFill(MaintenanceFill), deleteFill(UUID)
    case saveComponent(MaintenanceComponent)
    case saveRule(MaintenanceRule), deleteRule(UUID)
    case settings(MaintenanceSettings)
}

public enum MaintenanceValidationError: LocalizedError, Equatable {
    case missingWork, missingComponent, invalidValue, duplicateWork
    case invalidOdometerOrder, invalidInterval, duplicateInterval
    case fileLimit, recordFileLimit, ledgerFileLimit, invalidFile

    public var errorDescription: String? {
        switch self {
        case .missingWork: "Добавьте хотя бы одну работу."
        case .missingComponent: "Выберите компонент."
        case .invalidValue: "Проверьте числа, даты и длину полей."
        case .duplicateWork: "В записи есть повторяющиеся идентификаторы работ."
        case .invalidOdometerOrder: "Значение нарушает порядок показаний. Для исправления отметьте корректировку одометра."
        case .invalidInterval: "Задайте хотя бы один положительный интервал."
        case .duplicateInterval: "Такой интервал уже существует. Откройте его для редактирования."
        case .fileLimit: "Размер одного файла ограничен 2 МиБ."
        case .recordFileLimit: "На одну запись выделено до 8 МиБ и восьми вложений."
        case .ledgerFileLimit: "Достигнут общий лимит вложений 32 МиБ."
        case .invalidFile: "Поддерживаются непустые файлы изображений и PDF."
        }
    }
}

public struct MaintenanceLedger: Codable, Sendable {
    public static let fileByteLimit = 2 * 1_048_576
    public static let recordFileByteLimit = 8 * 1_048_576
    public static let ledgerFileByteLimit = 32 * 1_048_576

    public var records: [MaintenanceRecord]
    public var odometers: [MaintenanceOdometer]
    public var fills: [MaintenanceFill]
    public var customComponents: [MaintenanceComponent]
    public var rules: [MaintenanceRule]
    public var settings: MaintenanceSettings

    public init(records: [MaintenanceRecord] = [], odometers: [MaintenanceOdometer] = [],
                fills: [MaintenanceFill] = [], customComponents: [MaintenanceComponent] = [],
                rules: [MaintenanceRule] = [], settings: MaintenanceSettings = .init()) {
        self.records = records
        self.odometers = odometers
        self.fills = fills
        self.customComponents = customComponents
        self.rules = rules
        self.settings = settings
    }

    public var components: [MaintenanceComponent] { MaintenanceComponent.catalog + customComponents }
    public var attachmentBytes: Int { records.reduce(0) { $0 + $1.attachmentBytes } }
    public var latestOdometer: MaintenanceOdometer? {
        odometers.filter { $0.odometer.value != nil }.max { $0.date < $1.date }
    }

    public mutating func apply(_ change: MaintenanceChange) throws {
        switch change {
        case .saveRecord(let record):
            try validate(record)
            Self.upsert(record, in: &records)
        case .deleteRecord(let id): records.removeAll { $0.id == id }
        case .saveOdometer(let reading):
            guard reading.odometer.value != nil, Self.valid(reading.odometer), Self.valid(reading.engineHours),
                  reading.date.timeIntervalSinceReferenceDate.isFinite, reading.comment.count <= 4_000 else {
                throw MaintenanceValidationError.invalidValue
            }
            try validateOdometerOrder(reading)
            Self.upsert(reading, in: &odometers)
        case .deleteOdometer(let id): odometers.removeAll { $0.id == id }
        case .saveFill(let fill):
            guard Self.valid(fill.date), Self.valid(fill.odometer), fill.litres.isFinite,
                  fill.litres > 0, fill.litres <= 100_000, Self.validMinor(fill.unitPriceMinor),
                  Self.validMinor(fill.totalMinor), fill.fuel.count <= 100, fill.comment.count <= 4_000 else {
                throw MaintenanceValidationError.invalidValue
            }
            Self.upsert(fill, in: &fills)
        case .deleteFill(let id): fills.removeAll { $0.id == id }
        case .saveComponent(let component):
            guard !component.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, component.title.count <= 120,
                  !component.id.isEmpty, component.id.count <= 80,
                  !MaintenanceComponent.catalog.contains(where: { $0.id == component.id }) else {
                throw MaintenanceValidationError.invalidValue
            }
            Self.upsert(component, in: &customComponents)
        case .saveRule(let rule):
            try validate(rule)
            Self.upsert(rule, in: &rules)
        case .deleteRule(let id): rules.removeAll { $0.id == id }
        case .settings(let settings):
            guard (0...3650).contains(settings.leadDays), Self.validNumber(settings.leadKm),
                  Self.validNumber(settings.leadHours) else { throw MaintenanceValidationError.invalidValue }
            self.settings = settings
        }
    }

    public func redactedCopy() -> Self {
        var copy = self
        for index in copy.records.indices {
            copy.records[index].attachments.removeAll()
            copy.records[index].comment = ""
            for item in copy.records[index].work.indices {
                copy.records[index].work[item].comment = ""
                if var inspection = copy.records[index].work[item].inspection {
                    inspection.condition = ""
                    inspection.season = ""
                    inspection.dimensions = ""
                    for measurement in inspection.measurements.indices { inspection.measurements[measurement].source = "" }
                    copy.records[index].work[item].inspection = inspection
                }
                for part in copy.records[index].work[item].parts.indices {
                    copy.records[index].work[item].parts[part].maker = ""
                    copy.records[index].work[item].parts[part].partNumber = ""
                    copy.records[index].work[item].parts[part].specification = ""
                    copy.records[index].work[item].parts[part].unit = ""
                }
            }
        }
        for index in copy.odometers.indices { copy.odometers[index].comment = "" }
        for index in copy.fills.indices {
            copy.fills[index].comment = ""
            copy.fills[index].fuel = ""
        }
        for index in copy.customComponents.indices { copy.customComponents[index].title = "Пользовательский компонент" }
        for index in copy.rules.indices where copy.rules[index].source.kind == .owner {
            copy.rules[index].source = .init()
        }
        return copy
    }

    private func validate(_ record: MaintenanceRecord) throws {
        guard !record.work.isEmpty else { throw MaintenanceValidationError.missingWork }
        guard record.work.count <= 64, Self.valid(record.date), Self.valid(record.odometer), Self.valid(record.engineHours),
              record.enteredAt.timeIntervalSinceReferenceDate.isFinite, record.comment.count <= 4_000 else {
            throw MaintenanceValidationError.invalidValue
        }
        guard Set(record.work.map(\.id)).count == record.work.count,
              Set(record.attachments.map(\.id)).count == record.attachments.count else {
            throw MaintenanceValidationError.duplicateWork
        }
        let componentIDs = Set(components.map(\.id))
        for work in record.work {
            guard componentIDs.contains(work.componentID) else { throw MaintenanceValidationError.missingComponent }
            guard work.comment.count <= 4_000, Self.validMinor(work.laborCostMinor), work.parts.count <= 32,
                  Set(work.parts.map(\.id)).count == work.parts.count else { throw MaintenanceValidationError.invalidValue }
            for part in work.parts {
                guard Self.validMinor(part.costMinor), Self.validNumber(part.quantity), part.maker.count <= 200,
                      part.partNumber.count <= 200, part.specification.count <= 500, part.unit.count <= 40 else {
                    throw MaintenanceValidationError.invalidValue
                }
            }
            if let inspection = work.inspection {
                guard inspection.measurements.count <= 24, Self.valid(inspection.manufactureOrInstallation),
                      inspection.nextCheck?.timeIntervalSinceReferenceDate.isFinite != false,
                      inspection.dimensions.count <= 200, inspection.condition.count <= 4_000, inspection.season.count <= 100,
                      Set(inspection.measurements.map(\.id)).count == inspection.measurements.count,
                      inspection.measurements.allSatisfy({ Self.validNumber($0.value) && $0.source.count <= 400 }),
                      inspection.measurements.allSatisfy({ $0.kind != .discLimitMm || !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                else { throw MaintenanceValidationError.invalidValue }
            }
        }
        for file in record.attachments {
            guard file.data.count <= Self.fileByteLimit else { throw MaintenanceValidationError.fileLimit }
            guard !file.data.isEmpty, !file.filename.isEmpty, file.filename.count <= 240,
                  Self.allowedMedia.contains(file.mediaType) else { throw MaintenanceValidationError.invalidFile }
        }
        guard record.attachmentBytes <= Self.recordFileByteLimit, record.attachments.count <= 8 else {
            throw MaintenanceValidationError.recordFileLimit
        }
        let previous = records.first { $0.id == record.id }?.attachmentBytes ?? 0
        guard attachmentBytes - previous + record.attachmentBytes <= Self.ledgerFileByteLimit else {
            throw MaintenanceValidationError.ledgerFileLimit
        }
    }

    private func validate(_ rule: MaintenanceRule) throws {
        guard components.contains(where: { $0.id == rule.componentID }) else { throw MaintenanceValidationError.missingComponent }
        let months = rule.months.map { (1...600).contains($0) } ?? true
        let positiveNumbers = [rule.distanceKm, rule.engineHours].compactMap { $0 }
        let validNumbers = positiveNumbers.allSatisfy { $0 > 0 && Self.validNumber($0) }
        guard months, validNumbers, rule.months != nil || !positiveNumbers.isEmpty,
              rule.operation != .topUp, rule.source.citation.count <= 500,
              rule.source.applicability.count <= 500 else { throw MaintenanceValidationError.invalidInterval }
        if rule.source.kind == .manufacturer {
            guard rule.source.reference?.scheme == "https", !rule.source.citation.isEmpty, !rule.source.applicability.isEmpty else {
                throw MaintenanceValidationError.invalidInterval
            }
        }
        guard !rules.contains(where: {
            $0.id != rule.id && $0.componentID == rule.componentID && $0.operation == rule.operation
                && $0.regime == rule.regime && $0.source.kind == rule.source.kind
        }) else { throw MaintenanceValidationError.duplicateInterval }
    }

    private func validateOdometerOrder(_ reading: MaintenanceOdometer) throws {
        guard reading.odometer.certainty == .exact, let km = reading.odometer.value else { return }
        let exact = odometers.filter { $0.id != reading.id && $0.odometer.certainty == .exact }.sorted { $0.date < $1.date }
        if exact.contains(where: { $0.date == reading.date }) { throw MaintenanceValidationError.invalidOdometerOrder }
        if !reading.correction, let previous = exact.last(where: { $0.date < reading.date })?.odometer.value, km < previous {
            throw MaintenanceValidationError.invalidOdometerOrder
        }
        if let next = exact.first(where: { $0.date > reading.date }), !next.correction, let nextKM = next.odometer.value, km > nextKM {
            throw MaintenanceValidationError.invalidOdometerOrder
        }
    }

    public static let allowedMedia: Set<String> = ["image/jpeg", "image/png", "image/heic", "image/heif", "application/pdf"]

    private static func validNumber(_ number: Double?) -> Bool {
        number.map { $0.isFinite && (0...1_000_000_000).contains($0) } ?? true
    }
    private static func validMinor(_ number: Int64?) -> Bool {
        number.map { (0...1_000_000_000_000).contains($0) } ?? true
    }
    private static func valid(_ value: MaintenanceValue<Double>) -> Bool {
        validNumber(value.value) && ((value.value == nil) == (value.certainty == .unknown))
    }
    private static func valid(_ date: MaintenanceValue<Date>) -> Bool {
        date.value?.timeIntervalSinceReferenceDate.isFinite != false && ((date.value == nil) == (date.certainty == .unknown))
    }

    private static func upsert<Item: Identifiable>(_ item: Item, in list: inout [Item]) {
        if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item }
        else { list.append(item) }
    }
}
