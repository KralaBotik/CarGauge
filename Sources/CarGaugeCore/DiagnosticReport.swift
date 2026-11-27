import Foundation

public enum DiagnosticSensor: UInt8, CaseIterable, Codable, Sendable {
    case load = 0x04, coolant = 0x05, manifoldPressure = 0x0B, rpm = 0x0C
    case speed = 0x0D, intakeTemperature = 0x0F, airFlow = 0x10
    case engineRunTime = 0x1F, barometricPressure = 0x33, voltage = 0x42, maximumAirFlow = 0x50
    case fuelRate = 0x5E

    public var name: String {
        switch self {
        case .load: "Расчётная нагрузка"
        case .coolant: "Температура ОЖ"
        case .manifoldPressure: "Давление во впуске"
        case .rpm: "Обороты двигателя"
        case .speed: "Скорость по ЭБУ"
        case .intakeTemperature: "Температура воздуха на впуске"
        case .airFlow: "Массовый расход воздуха"
        case .maximumAirFlow: "Шкала расхода воздуха"
        case .engineRunTime: "Время работы по ЭБУ"
        case .barometricPressure: "Барометрическое давление"
        case .voltage: "Напряжение ЭБУ"
        case .fuelRate: "Расход топлива по ЭБУ"
        }
    }

    public var unit: String {
        switch self {
        case .load: "%"
        case .coolant, .intakeTemperature: "°C"
        case .manifoldPressure, .barometricPressure: "кПа"
        case .rpm: "об/мин"
        case .speed: "км/ч"
        case .airFlow, .maximumAirFlow: "г/с"
        case .engineRunTime: "с"
        case .voltage: "В"
        case .fuelRate: "л/ч"
        }
    }

    var byteCount: Int {
        switch self {
        case .rpm, .airFlow, .engineRunTime, .voltage, .fuelRate: 2
        case .maximumAirFlow: 4
        default: 1
        }
    }

    func value(_ bytes: [UInt8]) -> Double? {
        let a = Double(bytes[0])
        let word = bytes.reduce(0) { ($0 << 8) | Int($1) }
        return switch self {
        case .load: a * 100 / 255
        case .coolant, .intakeTemperature: a - 40
        case .manifoldPressure, .barometricPressure, .speed: a
        case .rpm: Double(word) / 4
        case .airFlow, .maximumAirFlow: nil // Retain bytes until the same ECU can be identified across PIDs.
        case .engineRunTime: Double(word)
        case .voltage: Double(word) / 1000
        case .fuelRate: Double(word) / 20
        }
    }

    public var pid: String { String(format: "%02X", rawValue) }
}

public enum DiagnosticCodeStatus: String, CaseIterable, Codable, Sendable {
    case stored, pending, permanent

    var service: UInt8 {
        switch self {
        case .stored: 0x03
        case .pending: 0x07
        case .permanent: 0x0A
        }
    }

    public var title: String {
        switch self {
        case .stored: "Сохранённые"
        case .pending: "Ожидающие"
        case .permanent: "Постоянные"
        }
    }
}

public struct DiagnosticPage: Codable, Sendable, Equatable {
    public let mode: UInt8
    public let basePID: UInt8
    /// Anonymous reply masks. Their order is local to this request.
    public let masks: [UInt32]

    public var advertisedPIDs: [String] {
        let union = masks.reduce(0, |)
        return (1...32).compactMap { offset in
            let pid = Int(basePID) + offset
            guard pid <= 0xFF, union & (0x8000_0000 >> (offset - 1)) != 0 else { return nil }
            return String(format: "%02X", pid)
        }
    }

    public func advertises(_ sensor: DiagnosticSensor) -> Bool {
        advertisedPIDs.contains(sensor.pid)
    }
}

public struct DiagnosticReadiness: Codable, Sendable, Equatable {
    public struct Monitor: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let supported: Bool
        /// Nil for an unsupported monitor. Ignition type is recorded separately.
        public let complete: Bool?
    }

    public let milOn: Bool
    public let confirmedCodeCount: Int
    public let compressionIgnition: Bool
    public let monitors: [Monitor]
    public let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
        milOn = bytes[0] & 0x80 != 0
        confirmedCodeCount = Int(bytes[0] & 0x7F)
        compressionIgnition = bytes[1] & 0x08 != 0

        func monitor(_ name: String, supported: Bool, incomplete: Bool) -> Monitor {
            Monitor(name: name, supported: supported, complete: supported ? !incomplete : nil)
        }
        let continuous = ["Пропуски воспламенения", "Топливная система", "Компоненты"]
        var list = continuous.enumerated().map { i, name in
            monitor(name, supported: bytes[1] & (1 << i) != 0, incomplete: bytes[1] & (1 << (i + 4)) != 0)
        }
        let emissions: [(Int, String)] = compressionIgnition
            ? [(0, "Катализатор NMHC"), (1, "NOx/SCR"), (3, "Давление наддува"),
               (5, "Датчик выхлопа"), (6, "Сажевый фильтр"), (7, "EGR/VVT")]
            : [(0, "Катализатор"), (1, "Подогреваемый катализатор"), (2, "EVAP"), (3, "Вторичный воздух"),
               (5, "Датчики кислорода"), (6, "Подогрев датчиков кислорода"), (7, "EGR/VVT")]
        list += emissions.map { i, name in
            monitor(name, supported: bytes[2] & (1 << i) != 0, incomplete: bytes[3] & (1 << i) != 0)
        }
        monitors = list
    }
}

public struct DiagnosticMeasurement: Codable, Sendable, Equatable {
    public let sensor: DiagnosticSensor
    public let value: Double?
    public let rawBytes: [UInt8]
    /// Timestamp of collection, including for freeze-frame data. The fault time may be unknown.
    public let collectedAt: Date
    public let freezeFrame: UInt8?
    public let responseIndex: Int

    public var origin: String { freezeFrame == nil ? "ecu_reported" : "ecu_freeze_frame" }
}

public struct DiagnosticExchange: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case received, noData, unsupported, negative, malformed, timeout, transportError, cancelled

        public var title: String {
            switch self {
            case .received: "Ответ получен"
            case .noData: "Нет данных"
            case .unsupported: "Команда отклонена"
            case .negative: "Отрицательный ответ ЭБУ"
            case .malformed: "Ответ не разобран"
            case .timeout: "Тайм-аут"
            case .transportError: "Ошибка связи или адаптера"
            case .cancelled: "Запрос прерван"
            }
        }
    }

    public let command: String
    public let startedAt: Date
    public let finishedAt: Date
    public let elapsedMilliseconds: Int
    public internal(set) var outcome: Outcome
    public internal(set) var detail: String?
    public internal(set) var rawResponse: String?
}

public struct DiagnosticReport: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, completed, interrupted
    }

    public struct CodeGroup: Codable, Sendable {
        public let status: DiagnosticCodeStatus
        /// Each list belongs to one anonymous reply. The same ECU cannot be tracked across requests.
        public let replyGroups: [[String]]
    }

    public struct Module: Codable, Sendable, Identifiable {
        public enum Status: String, Codable, Sendable {
            case answeredGenericOBD, notChecked, profileUnverified
        }
        public let id: String
        public let name: String
        public let status: Status
    }

    public static let currentSchema = 1
    public let schemaVersion: Int
    public let id: UUID
    public let startedAt: Date
    public let firstObservedCoolantAt: Date?
    public let adapterName: String?
    public let adapterIdentification: String?
    public let source: String
    public let stationaryConfirmedByUser: Bool
    public internal(set) var state: State = .running
    public internal(set) var finishedAt: Date?
    public internal(set) var interruption: String?
    public internal(set) var transportProtocol: DiagnosticProtocol?
    public internal(set) var pages: [DiagnosticPage] = []
    public internal(set) var codes: [CodeGroup] = []
    public internal(set) var freezeCauses: [String] = []
    public internal(set) var readiness: [DiagnosticReadiness] = []
    public internal(set) var measurements: [DiagnosticMeasurement] = []
    public internal(set) var exchanges: [DiagnosticExchange] = []
    public var vehicle: [String: String] {
        ["make": "Hyundai", "model": "Elantra HD", "year": "2011",
         "engine": "G4FC 1.6", "transmission": "manual", "origin": "owner_supplied_profile"]
    }
    public var modules: [Module] {
        let genericReply = exchanges.contains { $0.outcome == .received && !$0.command.hasPrefix("AT") }
        return [
            Module(id: "emissions", name: "Стандартный OBD · выбросы",
                   status: genericReply ? .answeredGenericOBD : .notChecked),
            Module(id: "abs", name: "ABS/ESP", status: .profileUnverified),
            Module(id: "srs", name: "SRS", status: .profileUnverified),
            Module(id: "eps", name: "EPS", status: .profileUnverified),
            Module(id: "bcm", name: "BCM", status: .profileUnverified),
            Module(id: "other", name: "Другие блоки", status: .profileUnverified)
        ]
    }

    init(startedAt: Date, firstObservedCoolantAt: Date?, adapterName: String?, adapterIdentification: String?,
         source: DataSource, stationaryConfirmedByUser: Bool) {
        schemaVersion = Self.currentSchema
        id = UUID()
        self.startedAt = startedAt
        self.firstObservedCoolantAt = firstObservedCoolantAt
        self.adapterName = adapterName
        self.adapterIdentification = adapterIdentification
        self.source = source == .vehicle ? "vehicle" : "test_fixture"
        self.stationaryConfirmedByUser = stationaryConfirmedByUser
    }

    private struct ExportEnvelope: Encodable {
        let schemaVersion: Int
        let vehicle: [String: String]
        let modules: [Module]
        let conditions: [String: String]
        let survey: DiagnosticReport
    }

    public func json(includeRaw: Bool) throws -> Data {
        var copy = self
        if !includeRaw {
            for i in copy.exchanges.indices { copy.exchanges[i].rawResponse = nil }
        }
        let document = ExportEnvelope(
            schemaVersion: schemaVersion, vehicle: vehicle, modules: modules,
            conditions: ["ecuAddressing": "generic_obd_functional_anonymous_replies",
                         "beforeFirstObservation": "unknown",
                         "gps": "not_collected", "motion": "not_verified_at_every_request",
                         "stationaryConfirmation": stationaryConfirmedByUser ? "user_confirmed" : "not_recorded",
                         "freezeFrameTimestamp": "read_time_not_fault_time",
                         "rawResponses": includeRaw ? "assembled_elm_text_when_available" : "excluded"],
            survey: copy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(document)
    }

    public func recoveredAfterRestart() -> Self {
        guard state == .running else { return self }
        var copy = self
        copy.state = .interrupted
        copy.finishedAt = exchanges.last?.finishedAt ?? startedAt
        copy.interruption = "Приложение завершилось во время обследования"
        return copy
    }

    public func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let columns = "collected_at_utc,origin,freeze_frame,pid,reply_in_request,value,unit,raw_pid_bytes"
        let rows = measurements.map { sample in
            let frame = sample.freezeFrame.map { String($0) } ?? ""
            let value = sample.value.map { String($0) } ?? ""
            let raw = sample.rawBytes.map { String(format: "%02X", $0) }.joined()
            let fields = [iso.string(from: sample.collectedAt), sample.origin, frame, sample.sensor.pid,
                          String(sample.responseIndex), value, sample.sensor.unit, raw]
            return fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        return ([columns] + rows).joined(separator: "\n") + "\n"
    }

    public func summary() -> String {
        let status = state == .completed ? "Очередь запросов завершена" : "Обследование неполное"
        let codeRows = DiagnosticCodeStatus.allCases.map { item in
            guard let groups = codes.first(where: { $0.status == item })?.replyGroups else {
                return "\(item.title): нет достоверного результата"
            }
            let values = Array(Set(groups.flatMap { $0 })).sorted()
            let description = values.isEmpty ? "коды не сообщены в полученных ответах" : values.joined(separator: ", ")
            return "\(item.title): \(description)"
        }
        let commandRows = exchanges.map { "\($0.command) · \($0.outcome.title) · \($0.elapsedMilliseconds) мс" }
        return (["CarGauge · Hyundai Elantra HD / G4FC", status,
                 source == "vehicle" ? "Источник: автомобиль" : "Источник: тестовая фикстура",
                 "Адаптер: \(adapterName ?? "имя недоступно")",
                 "Протокол: \(transportProtocol?.rawValue ?? "не установлен")",
                 "Пропущенная работа двигателя до первого наблюдения: неизвестна",
                 "Координаты не собираются",
                 "Ответы стандартного OBD не подтверждают состояние других блоков.",
                 ""] + codeRows + ["", "Запросов: \(exchanges.count)", ""] + commandRows).joined(separator: "\n") + "\n"
    }
}
