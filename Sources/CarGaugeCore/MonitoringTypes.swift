import Foundation

public enum MonitoringRegime: String, CaseIterable, Codable, Sendable {
    case unknown, ignitionOn, coldStart, warmingUp, warmIdle, moving, higherLoad, decelerationCandidate

    public var title: String {
        switch self {
        case .unknown: "Режим неизвестен"
        case .ignitionOn: "ЭБУ доступен, двигатель остановлен"
        case .coldStart: "Наблюдавшийся холодный запуск"
        case .warmingUp: "Двигатель ниже выбранной рабочей температуры"
        case .warmIdle: "Прогретый холостой ход"
        case .moving: "Движение"
        case .higherLoad: "Движение с повышенной нагрузкой"
        case .decelerationCandidate: "Возможное замедление при закрытом дросселе"
        }
    }
}

public enum MonitoringSeverity: String, CaseIterable, Codable, Sendable {
    case info, warning, critical

    var priority: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public var title: String {
        switch self {
        case .info: "Наблюдение"
        case .warning: "Предупреждение"
        case .critical: "Срочное предупреждение"
        }
    }
}

public enum MonitoringState: String, Codable, Sendable {
    case insufficientData, notApplicable, observing, normal, deviation, problem, recovered

    public var title: String {
        switch self {
        case .insufficientData: "Недостаточно данных"
        case .notApplicable: "Не применимо"
        case .observing: "Наблюдение"
        case .normal: "Условие не сработало"
        case .deviation: "Отклонение"
        case .problem: "Проблема"
        case .recovered: "Восстановление"
        }
    }
}

public enum MonitoringOrigin: String, Codable, Sendable {
    case oem, userThreshold, engineering, experimental, individual

    public var title: String {
        switch self {
        case .oem: "Норма производителя"
        case .userThreshold: "Порог пользователя"
        case .engineering: "Инженерное наблюдение"
        case .experimental: "Экспериментальное правило"
        case .individual: "Индивидуальное сравнение"
        }
    }
}

public enum MonitoringAggregate: String, Codable, Sendable {
    case average, minimum, maximum, median, spread

    var title: String {
        switch self {
        case .average: "Среднее"
        case .minimum: "Минимум"
        case .maximum: "Максимум"
        case .median: "Медиана"
        case .spread: "Размах"
        }
    }
}

public struct MonitoringWindow: Codable, Sendable {
    public let signal: DriveSignal
    public let aggregate: MonitoringAggregate
    public let duration: Double
    public let minimumSamples: Int
    public let minimumSpan: Double
    public let maximumGap: Double
    public let maximumAge: Double
    public let closedLoopOnly: Bool

    public init(_ signal: DriveSignal, _ aggregate: MonitoringAggregate, duration: Double, minimumSamples: Int,
                minimumSpan: Double, maximumGap: Double, maximumAge: Double, closedLoopOnly: Bool = false) {
        self.signal = signal
        self.aggregate = aggregate
        self.duration = duration
        self.minimumSamples = minimumSamples
        self.minimumSpan = minimumSpan
        self.maximumGap = maximumGap
        self.maximumAge = maximumAge
        self.closedLoopOnly = closedLoopOnly
    }
}

public enum MonitoringThermalLimit: String, Codable, Sendable {
    case operating, warning, critical
}

public indirect enum MonitoringMetric: Codable, Sendable {
    case reading(DriveSignal, maximumAge: Double)
    case aggregate(MonitoringWindow)
    case difference(MonitoringMetric, MonitoringMetric)
    case sum(MonitoringMetric, MonitoringMetric)
    case baselineDifference(DriveSignal, maximumAge: Double)
    case baselineMAD(DriveSignal)
    case constant(Double)
    case thermalLimit(MonitoringThermalLimit, offset: Double)
    case witnessedRuntime
    case initialCoolant
    case adapterVoltageReference(maximumAge: Double)
}

public enum MonitoringComparator: String, Codable, Sendable {
    case below, atMost, above, atLeast, equal

    func test(_ a: Double, _ b: Double) -> Bool {
        switch self {
        case .below: a < b
        case .atMost: a <= b
        case .above: a > b
        case .atLeast: a >= b
        case .equal: a == b
        }
    }
}

public indirect enum MonitoringCondition: Codable, Sendable {
    case always(Bool)
    case all([MonitoringCondition])
    case any([MonitoringCondition])
    case compare(MonitoringMetric, MonitoringComparator, MonitoringMetric)
    case available(MonitoringMetric)
    case regimes(Set<MonitoringRegime>)
    case closedLoop
    case witnessedColdStart
    case reachedOperating
    case readingsNear(DriveSignal, DriveSignal, maximumSeparation: Double, maximumAge: Double)
}

public struct MonitoringRule: Identifiable, Codable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let severity: MonitoringSeverity
    public let origin: MonitoringOrigin
    public let sourceURL: String
    public let applicability: String
    public let rationale: String
    public let possibleCauses: [String]
    public let limitations: String
    public let correlationKey: String
    public let relevantDTCs: Set<String>
    public let enabledByDefault: Bool
    public let opensIssue: Bool
    public let applicableWhen: MonitoringCondition
    public let trigger: MonitoringCondition
    public let recovery: MonitoringCondition
    public let minimumViolation: Double
    public let minimumRecovery: Double
    public let notificationCooldown: Double
    public let context: [MonitoringMetric]
    public var key: String { "\(id)@\(version)" }

    public init(id: String, version: Int, title: String, severity: MonitoringSeverity,
                origin: MonitoringOrigin, sourceURL: String, applicability: String, rationale: String,
                possibleCauses: [String], limitations: String, correlationKey: String, relevantDTCs: Set<String> = [],
                enabledByDefault: Bool = true, opensIssue: Bool = true, applicableWhen: MonitoringCondition,
                trigger: MonitoringCondition, recovery: MonitoringCondition,
                minimumViolation: Double, minimumRecovery: Double, notificationCooldown: Double = 900,
                context: [MonitoringMetric] = []) {
        self.id = id
        self.version = version
        self.title = title
        self.severity = severity
        self.origin = origin
        self.sourceURL = sourceURL
        self.applicability = applicability
        self.rationale = rationale
        self.possibleCauses = possibleCauses
        self.limitations = limitations
        self.correlationKey = correlationKey
        self.relevantDTCs = relevantDTCs
        self.enabledByDefault = enabledByDefault
        self.opensIssue = opensIssue
        self.applicableWhen = applicableWhen
        self.trigger = trigger
        self.recovery = recovery
        self.minimumViolation = minimumViolation
        self.minimumRecovery = minimumRecovery
        self.notificationCooldown = notificationCooldown
        self.context = context
    }
}

public struct MonitoringFrame: Sendable {
    public let timestamp: Date
    public let monotonic: Double
    public let readings: [DriveSignal: DriveReading]
    public let tripID: Int64?
    public let engineStartObserved: Bool
    public let activeDTCs: Set<String>
    public let fuelLitresPer100km: Double?
    public let thermalThresholds: ThermalThresholds
    public let dtcCoverageKnown: Bool
    public let adapterVoltageOffset: Double?

    public init(timestamp: Date, monotonic: Double, readings: [DriveSignal: DriveReading],
                tripID: Int64? = nil, engineStartObserved: Bool = false, activeDTCs: Set<String> = [],
                fuelLitresPer100km: Double? = nil, thermalThresholds: ThermalThresholds = .standard,
                dtcCoverageKnown: Bool = false, adapterVoltageOffset: Double? = nil) {
        self.timestamp = timestamp
        self.monotonic = monotonic
        self.readings = readings
        self.tripID = tripID
        self.engineStartObserved = engineStartObserved
        self.activeDTCs = activeDTCs
        self.fuelLitresPer100km = fuelLitresPer100km
        self.thermalThresholds = thermalThresholds
        self.dtcCoverageKnown = dtcCoverageKnown
        self.adapterVoltageOffset = adapterVoltageOffset
    }
}

public struct MonitoringEvidence: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case ecu, adapter, calculated, statistical, configured, context
    }

    public let id: String
    public let title: String
    public let value: Double
    public let unit: String
    public let observedAt: Date?
    public let source: Source
}

public struct MonitoringEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case problem, recovery }

    public let id: UUID
    public let issueID: UUID
    public let correlationID: UUID
    public let ruleID: String
    public let ruleVersion: Int
    public let kind: Kind
    public let occurredAt: Date
    public let tripID: Int64?
    public let duration: Double?
    public let severity: MonitoringSeverity
    public let regime: MonitoringRegime
    public let evidence: [MonitoringEvidence]
    public let relatedDTCs: [String]
    public let correlationKey: String
    public let shouldNotify: Bool
}

public struct MonitoringRuleResult: Identifiable, Codable, Sendable {
    public var id: String { ruleID }
    public let ruleID: String
    public let ruleVersion: Int
    public let state: MonitoringState
    public let issueID: UUID?
    public let evidence: [MonitoringEvidence]
    public let enabled: Bool
}

public struct MonitoringUpdate: Sendable {
    public let regime: MonitoringRegime
    public let results: [MonitoringRuleResult]
    public let events: [MonitoringEvent]
    public let baseline: [MonitoringBaselineInfo]
}

public struct MonitoringCheckpoint: Codable, Sendable {
    public let schemaVersion: Int
    public let openIssues: [MonitoringEvent]
    public let enabledOverrides: [String: Bool]
    let baseline: MonitoringBaseline
    let notices: [String: MonitoringNotice]
}

struct MonitoringNotice: Codable, Sendable {
    let occurredAt: Date
    let severity: MonitoringSeverity
}
