import Foundation

public enum DriveSignal: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case monitors = 0x01, fuelStatus = 0x03, load = 0x04, coolant = 0x05
    case shortTrim = 0x06, longTrim = 0x07, map = 0x0B, rpm = 0x0C, speed = 0x0D
    case timing = 0x0E, intake = 0x0F, throttle = 0x11, oxygenPresence = 0x13
    case oxygen1 = 0x14, oxygen2 = 0x15, standard = 0x1C, runTime = 0x1F
    case distanceWithMIL = 0x21, evaporativePurge = 0x2E, warmups = 0x30, distanceSinceClear = 0x31
    case catalyst = 0x3C, currentMonitors = 0x41, ecuVoltage = 0x42, absoluteLoad = 0x43
    case commandedLambda = 0x44, relativeThrottle = 0x45, ambient = 0x46
    // Local identifier outside the standard catalogue. Never sent to the ECU.
    case adapterVoltage = 0xFF

    public var id: UInt8 { rawValue }
    public var command: String { self == .adapterVoltage ? "ATRV" : String(format: "01%02X", rawValue) }
    public var title: String {
        switch self {
        case .monitors: "Готовность мониторов"
        case .fuelStatus: "Режим топливной системы"
        case .load: "Расчётная нагрузка"
        case .coolant: "Температура ОЖ"
        case .shortTrim: "Краткосрочная коррекция"
        case .longTrim: "Долгосрочная коррекция"
        case .map: "Давление во впуске"
        case .rpm: "Обороты"
        case .speed: "Скорость"
        case .timing: "Опережение зажигания"
        case .intake: "Температура на впуске"
        case .throttle: "Положение дросселя"
        case .oxygenPresence: "Доступные датчики кислорода"
        case .oxygen1: "Кислородный датчик B1S1"
        case .oxygen2: "Кислородный датчик B1S2"
        case .standard: "Стандарт OBD"
        case .runTime: "Время работы двигателя по ЭБУ"
        case .distanceWithMIL: "Расстояние с включённым MIL"
        case .evaporativePurge: "Заданная продувка адсорбера"
        case .warmups: "Прогревы после очистки DTC"
        case .distanceSinceClear: "Пробег после очистки DTC"
        case .catalyst: "Температура катализатора B1S1"
        case .currentMonitors: "Мониторы текущего цикла"
        case .ecuVoltage: "Напряжение ЭБУ"
        case .absoluteLoad: "Абсолютная нагрузка"
        case .commandedLambda: "Заданное отношение смеси"
        case .relativeThrottle: "Относительное положение дросселя"
        case .ambient: "Температура наружного воздуха"
        case .adapterVoltage: "Напряжение адаптера"
        }
    }

    public var unit: String {
        switch self {
        case .coolant, .intake, .catalyst, .ambient: "°C"
        case .map: "кПа"
        case .rpm: "об/мин"
        case .speed: "км/ч"
        case .load, .absoluteLoad, .shortTrim, .longTrim, .throttle, .relativeThrottle, .evaporativePurge: "%"
        case .timing: "°"
        case .oxygen1, .oxygen2, .ecuVoltage, .adapterVoltage: "В"
        case .distanceWithMIL, .distanceSinceClear: "км"
        case .runTime: "с"
        default: ""
        }
    }

    var length: Int {
        switch self {
        case .monitors, .currentMonitors: 4
        case .fuelStatus, .rpm, .oxygen1, .oxygen2, .runTime, .distanceWithMIL, .distanceSinceClear,
             .catalyst, .ecuVoltage, .absoluteLoad, .commandedLambda: 2
        default: 1
        }
    }

    func decode(_ bytes: [UInt8]) -> Double? {
        let a = Double(bytes[0])
        let ab = bytes.count >= 2 ? a * 256 + Double(bytes[1]) : a
        return switch self {
        case .monitors, .currentMonitors, .oxygenPresence, .adapterVoltage: nil
        case .fuelStatus, .map, .speed, .standard, .warmups: a
        case .runTime, .distanceWithMIL, .distanceSinceClear: ab
        case .coolant, .intake, .ambient: a - 40
        case .rpm: ab / 4
        case .load, .throttle, .relativeThrottle, .evaporativePurge: a * 100 / 255
        case .absoluteLoad: ab * 100 / 255
        case .shortTrim, .longTrim: (a - 128) * 100 / 128
        case .timing: a / 2 - 64
        case .oxygen1, .oxygen2: a / 200
        case .catalyst: ab / 10 - 40
        case .ecuVoltage: ab / 1000
        case .commandedLambda: ab / 32768
        }
    }

    public var displayLifetime: Double { max(4, cadence * 2.5) }

    var cadence: Double {
        switch self {
        case .speed, .map: 1
        case .fuelStatus: 2
        case .commandedLambda: 6
        case .runTime: 8
        case .intake: 10
        case .timing, .load, .absoluteLoad, .throttle, .relativeThrottle, .shortTrim, .longTrim: 12
        case .oxygen1, .oxygen2, .evaporativePurge, .catalyst, .ambient: 30
        default: 90
        }
    }

    static let extra = allCases.filter { ![.coolant, .rpm, .ecuVoltage, .adapterVoltage].contains($0) }
}

public struct DriveReading: Codable, Equatable, Sendable {
    public enum Quality: String, Codable, Sendable { case received, noData, unsupported, malformed, ambiguous }
    public let signal: DriveSignal
    public let value: Double?
    public let bytes: [UInt8]
    public let timestamp: Date
    public let monotonic: Double
    public let quality: Quality

    public init(signal: DriveSignal, value: Double?, bytes: [UInt8], timestamp: Date,
                monotonic: Double, quality: Quality = .received) {
        self.signal = signal
        self.value = value
        self.bytes = bytes
        self.timestamp = timestamp
        self.monotonic = monotonic
        self.quality = quality
    }

    public func isFresh(at time: Double, within interval: Double) -> Bool {
        quality == .received && time >= monotonic && time - monotonic <= interval
    }

    static func decode(_ signal: DriveSignal, response: String, timestamp: Date, monotonic: Double) throws -> Self {
        let replies = try DiagnosticDecoder.modePID(mode: 1, pid: signal.rawValue, bytes: signal.length, response: response)
        guard let bytes = replies.first else { throw OBDError.malformedResponse }
        guard replies.count == 1 else { throw OBDError.ambiguousResponse }
        return Self(signal: signal, value: signal.decode(bytes), bytes: bytes, timestamp: timestamp, monotonic: monotonic)
    }
}

/// Mask bits follow SAE J1979 from the MSB (base + 1) to the LSB (base + 32).
public struct VehiclePollPlan: Sendable {
    public static let referenceMasks: [UInt8: UInt32] = [0x00: 0xBE3EB813, 0x20: 0x80058011, 0x40: 0xBC000000]
    public private(set) var masks: [UInt8: UInt32] = [:]
    private var last: [DriveSignal: Double] = [:]

    public init() {}

    public static func advertised(base: UInt8, mask: UInt32) -> [UInt8] {
        let count = min(32, 255 - Int(base))
        let highBit: UInt32 = 0x8000_0000
        var pids: [UInt8] = []
        for bit in 0..<count where mask & (highBit >> bit) != 0 {
            pids.append(base + UInt8(bit + 1))
        }
        return pids
    }

    public var isTargetProfile: Bool { masks == Self.referenceMasks }

    public func supports(_ signal: DriveSignal) -> Bool {
        let base = (signal.rawValue - 1) & 0xE0
        guard let mask = masks[base] else { return false }
        return Self.advertised(base: base, mask: mask).contains(signal.rawValue)
    }

    public mutating func record(page: OBDSupportPage, bits: UInt32) { masks[page.base] = bits }

    public mutating func next(at now: Double, background: Bool) -> [DriveSignal] {
        let priority: [DriveSignal] = [.speed, .map, .fuelStatus, .intake, .runTime, .commandedLambda]
        let urgent = Array(priority.prefix(2)).filter { supports($0) && isDue($0, at: now, background: background) }
        let regular = DriveSignal.extra.filter { signal in
            supports(signal) && !priority.prefix(2).contains(signal)
                && (!background || priority.contains(signal))
                && isDue(signal, at: now, background: background)
        }
        // Reserve one non-critical slot so slow channels eventually get serviced.
        let extra = regular.max { lhs, rhs in
            waitScore(lhs, at: now, priority: priority) < waitScore(rhs, at: now, priority: priority)
        }
        let requests = urgent + (extra.map { [$0] } ?? [])
        for signal in requests { last[signal] = now }
        return requests
    }

    private func isDue(_ signal: DriveSignal, at now: Double, background: Bool) -> Bool {
        guard let time = last[signal] else { return true }
        return now - time >= signal.cadence * (background ? 2 : 1)
    }

    private func waitScore(_ signal: DriveSignal, at now: Double, priority: [DriveSignal]) -> Double {
        guard let time = last[signal] else { return priority.contains(signal) ? 8 : 3 }
        return (now - time) / signal.cadence
    }
}

/// Time since this process first used the recorder. Values are never compared across launches.
public enum DriveClock {
    private static let origin = ContinuousClock.now

    public static var now: Double {
        let duration = origin.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

/// Timeout invalidates the transport but does not quarantine primary telemetry.
public struct OptionalPollCooldown: Sendable {
    private var deferred: [String: Double] = [:]
    public init() {}

    public func allows(_ command: String, at time: Double) -> Bool {
        deferred[command].map { time >= $0 } ?? true
    }

    public mutating func timedOut(_ command: String, at time: Double) {
        deferred[command] = time + 60
    }
}
