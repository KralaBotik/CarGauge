import Foundation

public enum MaintenanceCertainty: String, Codable, Sendable, CaseIterable, Identifiable {
    case unknown, approximate, exact
    public var id: Self { self }
    public var title: String {
        switch self {
        case .unknown: "Неизвестно"
        case .approximate: "Приблизительно"
        case .exact: "Точно"
        }
    }
}

public struct MaintenanceValue<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value?
    public var certainty: MaintenanceCertainty

    public init(_ value: Value? = nil, certainty: MaintenanceCertainty = .exact) {
        self.value = certainty == .unknown ? nil : value
        self.certainty = self.value == nil ? .unknown : certainty
    }
}

public enum MaintenanceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case engine, cooling, brakes, transmission, electrical, suspension, other
    public var id: Self { self }
    public var title: String {
        switch self {
        case .engine: "Двигатель"
        case .cooling: "Охлаждение"
        case .brakes: "Тормоза"
        case .transmission: "Трансмиссия"
        case .electrical: "Электрика"
        case .suspension: "Ходовая и рулевое"
        case .other: "Прочее"
        }
    }
}

public enum MaintenancePolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case replacement, inspection, condition
    public var id: Self { self }
    public var title: String {
        switch self {
        case .replacement: "Замена по применимому интервалу"
        case .inspection: "Периодический осмотр"
        case .condition: "По фактическому состоянию"
        }
    }
}

public struct MaintenanceComponent: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var title: String
    public var category: MaintenanceCategory
    public var policy: MaintenancePolicy

    public init(id: String = UUID().uuidString, title: String, category: MaintenanceCategory, policy: MaintenancePolicy) {
        self.id = id
        self.title = title
        self.category = category
        self.policy = policy
    }

    public static let catalog: [Self] = [
        .init(id: "engine-oil", title: "Моторное масло", category: .engine, policy: .replacement),
        .init(id: "oil-filter", title: "Масляный фильтр", category: .engine, policy: .replacement),
        .init(id: "air-filter", title: "Воздушный фильтр", category: .engine, policy: .replacement),
        .init(id: "spark-plugs", title: "Свечи зажигания", category: .engine, policy: .replacement),
        .init(id: "fuel-filter", title: "Топливный фильтр", category: .engine, policy: .replacement),
        .init(id: "timing-chain", title: "Цепь ГРМ", category: .engine, policy: .condition),
        .init(id: "chain-tensioner", title: "Натяжитель и направляющие цепи", category: .engine, policy: .condition),
        .init(id: "drive-belt", title: "Приводной ремень", category: .engine, policy: .inspection),
        .init(id: "belt-rollers", title: "Ролики и натяжители ремня", category: .engine, policy: .condition),
        .init(id: "valve-clearance", title: "Клапанные зазоры", category: .engine, policy: .inspection),
        .init(id: "coolant", title: "Антифриз", category: .cooling, policy: .replacement),
        .init(id: "coolant-level", title: "Уровень охлаждающей жидкости", category: .cooling, policy: .inspection),
        .init(id: "coolant-hoses", title: "Патрубки", category: .cooling, policy: .inspection),
        .init(id: "radiator", title: "Радиатор", category: .cooling, policy: .condition),
        .init(id: "thermostat", title: "Термостат", category: .cooling, policy: .condition),
        .init(id: "water-pump", title: "Помпа", category: .cooling, policy: .condition),
        .init(id: "front-pads", title: "Передние колодки", category: .brakes, policy: .condition),
        .init(id: "rear-pads", title: "Задние колодки", category: .brakes, policy: .condition),
        .init(id: "front-discs", title: "Передние диски", category: .brakes, policy: .condition),
        .init(id: "rear-discs", title: "Задние диски", category: .brakes, policy: .condition),
        .init(id: "brake-fluid", title: "Тормозная жидкость", category: .brakes, policy: .replacement),
        .init(id: "callipers", title: "Суппорты и направляющие", category: .brakes, policy: .inspection),
        .init(id: "parking-brake", title: "Стояночный тормоз", category: .brakes, policy: .inspection),
        .init(id: "brake-hoses", title: "Тормозные шланги", category: .brakes, policy: .inspection),
        .init(id: "gearbox-oil", title: "Масло МКПП", category: .transmission, policy: .inspection),
        .init(id: "clutch", title: "Сцепление", category: .transmission, policy: .condition),
        .init(id: "drives", title: "Приводы и ШРУС", category: .transmission, policy: .condition),
        .init(id: "drive-boots", title: "Пыльники приводов", category: .transmission, policy: .inspection),
        .init(id: "battery", title: "Аккумулятор", category: .electrical, policy: .condition),
        .init(id: "alternator", title: "Генератор", category: .electrical, policy: .condition),
        .init(id: "starter", title: "Стартер", category: .electrical, policy: .condition),
        .init(id: "dampers", title: "Амортизаторы", category: .suspension, policy: .condition),
        .init(id: "springs", title: "Пружины", category: .suspension, policy: .condition),
        .init(id: "ball-joints", title: "Шаровые опоры", category: .suspension, policy: .inspection),
        .init(id: "tie-rod-ends", title: "Рулевые наконечники", category: .suspension, policy: .inspection),
        .init(id: "bushings", title: "Сайлентблоки", category: .suspension, policy: .condition),
        .init(id: "wheel-bearings", title: "Ступичные подшипники", category: .suspension, policy: .condition),
        .init(id: "cabin-filter", title: "Салонный фильтр", category: .other, policy: .replacement),
        .init(id: "wipers", title: "Щётки стеклоочистителей", category: .other, policy: .condition),
        .init(id: "tyres", title: "Шины", category: .other, policy: .condition),
        .init(id: "tyre-pressure", title: "Давление в шинах", category: .other, policy: .inspection),
        .init(id: "tyre-tread", title: "Глубина протектора", category: .other, policy: .inspection),
        .init(id: "tyre-age", title: "Возраст шин", category: .other, policy: .inspection),
        .init(id: "oxygen-sensors", title: "Датчики кислорода", category: .engine, policy: .condition)
    ]

    public var comparableSignals: [DriveSignal] {
        switch id {
        case "thermostat", "coolant", "radiator", "water-pump", "coolant-hoses": [.coolant]
        case "spark-plugs": [.rpm, .shortTrim, .longTrim]
        case "oxygen-sensors": [.oxygen1, .oxygen2, .shortTrim, .longTrim]
        case "battery", "alternator": [.adapterVoltage, .ecuVoltage]
        default: []
        }
    }
}

public enum MaintenanceOperation: String, Codable, Sendable, CaseIterable, Identifiable {
    case replacement, inspection, repair, adjustment, topUp
    public var id: Self { self }
    public var title: String {
        switch self {
        case .replacement: "Замена"
        case .inspection: "Осмотр"
        case .repair: "Ремонт"
        case .adjustment: "Регулировка"
        case .topUp: "Долив"
        }
    }
}

public enum MaintenanceFinding: String, Codable, Sendable, CaseIterable, Identifiable {
    case unknown, satisfactory, recheck, replacement
    public var id: Self { self }
    public var title: String {
        switch self {
        case .unknown: "Без оценки"
        case .satisfactory: "По осмотру замечаний нет"
        case .recheck: "Требуется повторный осмотр"
        case .replacement: "Осмотром рекомендована замена"
        }
    }
}

public enum MaintenanceMeasurementKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case frictionMm, discMm, discLimitMm, batteryVoltage, batteryAh, batteryCCA, tyreTreadMm, tyrePressureKPa
    public var id: Self { self }
    public var title: String {
        switch self {
        case .frictionMm: "Фрикционный слой, мм"
        case .discMm: "Толщина диска, мм"
        case .discLimitMm: "Подтверждённый минимум диска, мм"
        case .batteryVoltage: "Напряжение, В"
        case .batteryAh: "Ёмкость, А·ч"
        case .batteryCCA: "Пусковой ток, А"
        case .tyreTreadMm: "Протектор, мм"
        case .tyrePressureKPa: "Давление, кПа"
        }
    }
}

public enum MaintenancePosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case unspecified, front, rear, frontLeft, frontRight, rearLeft, rearRight
    public var id: Self { self }
    public var title: String {
        switch self {
        case .unspecified: "Не указано"
        case .front: "Передняя ось"
        case .rear: "Задняя ось"
        case .frontLeft: "Переднее левое"
        case .frontRight: "Переднее правое"
        case .rearLeft: "Заднее левое"
        case .rearRight: "Заднее правое"
        }
    }
}

public struct MaintenanceMeasurement: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MaintenanceMeasurementKind
    public var value: Double
    public var source: String

    public init(id: UUID = UUID(), kind: MaintenanceMeasurementKind, value: Double, source: String = "") {
        self.id = id
        self.kind = kind
        self.value = value
        self.source = source
    }
}

public struct MaintenanceInspection: Codable, Sendable {
    public var position: MaintenancePosition
    public var finding: MaintenanceFinding
    public var measurements: [MaintenanceMeasurement]
    public var nextCheck: Date?
    public var manufactureOrInstallation: MaintenanceValue<Date>
    public var dimensions: String
    public var condition: String
    public var season: String

    public init(position: MaintenancePosition = .unspecified, finding: MaintenanceFinding = .unknown,
                measurements: [MaintenanceMeasurement] = [], nextCheck: Date? = nil,
                manufactureOrInstallation: MaintenanceValue<Date> = .init(), dimensions: String = "",
                condition: String = "", season: String = "") {
        self.position = position
        self.finding = finding
        self.measurements = measurements
        self.nextCheck = nextCheck
        self.manufactureOrInstallation = manufactureOrInstallation
        self.dimensions = dimensions
        self.condition = condition
        self.season = season
    }
}

public struct MaintenancePart: Codable, Sendable, Identifiable {
    public var id: UUID
    public var maker: String
    public var partNumber: String
    public var specification: String
    public var quantity: Double?
    public var unit: String
    public var costMinor: Int64?

    public init(id: UUID = UUID(), maker: String = "", partNumber: String = "", specification: String = "",
                quantity: Double? = nil, unit: String = "", costMinor: Int64? = nil) {
        self.id = id
        self.maker = maker
        self.partNumber = partNumber
        self.specification = specification
        self.quantity = quantity
        self.unit = unit
        self.costMinor = costMinor
    }
}

public struct MaintenanceWork: Codable, Sendable, Identifiable {
    public var id: UUID
    public var componentID: String
    public var operation: MaintenanceOperation
    public var parts: [MaintenancePart]
    public var laborCostMinor: Int64?
    public var inspection: MaintenanceInspection?
    public var comment: String

    public init(id: UUID = UUID(), componentID: String, operation: MaintenanceOperation = .replacement,
                parts: [MaintenancePart] = [], laborCostMinor: Int64? = nil,
                inspection: MaintenanceInspection? = nil, comment: String = "") {
        self.id = id
        self.componentID = componentID
        self.operation = operation
        self.parts = parts
        self.laborCostMinor = laborCostMinor
        self.inspection = inspection
        self.comment = comment
    }

    var allCostsKnown: Bool { laborCostMinor != nil && parts.allSatisfy { $0.costMinor != nil } }
    var knownCost: Int64? {
        let amounts = [laborCostMinor].compactMap { $0 } + parts.compactMap(\.costMinor)
        return amounts.isEmpty ? nil : amounts.reduce(0, +)
    }
}

public enum MaintenanceProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case unknown, selfService, workshop
    public var id: Self { self }
    public var title: String {
        switch self {
        case .unknown: "Не указано"
        case .selfService: "Самостоятельно"
        case .workshop: "Автосервис"
        }
    }
}

public struct MaintenanceAttachment: Codable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mediaType: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, mediaType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.data = data
    }
}

public struct MaintenanceRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var enteredAt: Date
    public var date: MaintenanceValue<Date>
    public var odometer: MaintenanceValue<Double>
    public var engineHours: MaintenanceValue<Double>
    public var provider: MaintenanceProvider
    public var comment: String
    public var work: [MaintenanceWork]
    public var attachments: [MaintenanceAttachment]

    public init(id: UUID = UUID(), enteredAt: Date = .now, date: MaintenanceValue<Date> = .init(),
                odometer: MaintenanceValue<Double> = .init(), engineHours: MaintenanceValue<Double> = .init(),
                provider: MaintenanceProvider = .unknown, comment: String = "", work: [MaintenanceWork] = [],
                attachments: [MaintenanceAttachment] = []) {
        self.id = id
        self.enteredAt = enteredAt
        self.date = date
        self.odometer = odometer
        self.engineHours = engineHours
        self.provider = provider
        self.comment = comment
        self.work = work
        self.attachments = attachments
    }

    public var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }
    public var displayDate: Date { date.value ?? enteredAt }
}

public struct MaintenanceOdometer: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var odometer: MaintenanceValue<Double>
    public var engineHours: MaintenanceValue<Double>
    public var correction: Bool
    public var comment: String

    public init(id: UUID = UUID(), date: Date = .now, odometer: MaintenanceValue<Double>,
                engineHours: MaintenanceValue<Double> = .init(), correction: Bool = false, comment: String = "") {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.engineHours = engineHours
        self.correction = correction
        self.comment = comment
    }
}

public struct MaintenanceFill: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: MaintenanceValue<Date>
    public var odometer: MaintenanceValue<Double>
    public var litres: Double
    public var unitPriceMinor: Int64?
    public var totalMinor: Int64?
    public var fuel: String
    public var fullTank: Bool
    public var comment: String

    public init(id: UUID = UUID(), date: MaintenanceValue<Date>, odometer: MaintenanceValue<Double>,
                litres: Double, unitPriceMinor: Int64? = nil, totalMinor: Int64? = nil,
                fuel: String = "", fullTank: Bool, comment: String = "") {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.litres = litres
        self.unitPriceMinor = unitPriceMinor
        self.totalMinor = totalMinor
        self.fuel = fuel
        self.fullTank = fullTank
        self.comment = comment
    }

    public var knownCost: Int64? {
        guard let unitPriceMinor else { return totalMinor }
        let calculated = (litres * Double(unitPriceMinor)).rounded()
        return totalMinor ?? Int64(exactly: calculated)
    }
}
