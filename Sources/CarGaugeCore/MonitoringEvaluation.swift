import Foundation

struct MonitoringRunContext {
    let observedSince: Double
    let witnessed: Bool
    let initialCoolant: Double?
    let initialAmbient: Double?
    var reachedOperating = false

    var witnessedColdStart: Bool? {
        guard witnessed else { return false }
        guard let initialCoolant, let initialAmbient else { return nil }
        // A comparability gate for the experimental profile, not a manufacturer's cold-start definition.
        return abs(initialCoolant - initialAmbient) <= 10
    }
}

struct MonitoringValue {
    let value: Double
    let stamp: Double?
    var validUntil: Double? = nil
    let evidence: [MonitoringEvidence]
}

struct MonitoringTruth {
    let value: Bool?
    var stamp: Double? = nil
    var validUntil: Double? = nil
    var evidence: [MonitoringEvidence] = []

    static func combining(_ parts: [MonitoringTruth], all: Bool) -> Self {
        let decides = parts.filter { $0.value == !all }
        if !decides.isEmpty {
            return Self(value: !all, stamp: decides.compactMap(\.stamp).max(),
                        validUntil: decides.compactMap(\.validUntil).min(),
                        evidence: parts.flatMap(\.evidence))
        }
        let value = parts.allSatisfy { $0.value == all } ? all : nil
        return Self(value: value, stamp: parts.compactMap(\.stamp).min(),
                    validUntil: parts.compactMap(\.validUntil).min(),
                    evidence: parts.flatMap(\.evidence))
    }
}

struct MonitoringEvaluation {
    let frame: MonitoringFrame
    let regime: MonitoringRegime
    let context: MonitoringRunContext?
    let baseline: MonitoringBaseline
    let bucket: MonitoringBucket?
    let history: [DriveSignal: [DriveReading]]
    let regimeSince: Double
    let closedLoopSince: Double?
    var heldLimits: [String: Double] = [:]

    static func fresh(_ signal: DriveSignal, frame: MonitoringFrame, maximumAge: Double) -> DriveReading? {
        guard maximumAge.isFinite && maximumAge >= 0,
              let sample = frame.readings[signal], sample.signal == signal,
              sample.isFresh(at: frame.monotonic, within: maximumAge) else { return nil }
        return sample
    }

    func fresh(_ signal: DriveSignal, maximumAge: Double) -> DriveReading? {
        Self.fresh(signal, frame: frame, maximumAge: maximumAge)
    }

    func value(_ metric: MonitoringMetric) -> MonitoringValue? {
        switch metric {
        case .reading(let signal, let maximumAge):
            guard let sample = fresh(signal, maximumAge: maximumAge), let number = sample.value,
                  number.isFinite else { return nil }
            return scalar(number, id: signal.command, title: signal.title, unit: signal.unit,
                          stamp: sample.monotonic, date: sample.timestamp, validUntil: sample.monotonic + maximumAge,
                          source: signal == .adapterVoltage ? .adapter : .ecu)
        case .aggregate(let window):
            return aggregate(window)
        case .difference(let lhs, let rhs):
            return arithmetic(lhs, rhs, operation: -)
        case .sum(let lhs, let rhs):
            return arithmetic(lhs, rhs, operation: +)
        case .baselineDifference(let signal, let age):
            guard let bucket, let middle = baseline.info(.init(signal: signal, bucket: bucket)).median,
                  let live = value(.reading(signal, maximumAge: age)) else { return nil }
            let baseline = scalar(middle, id: "baseline.\(signal.command)", title: "Медиана автомобиля · \(signal.title)",
                                  unit: signal.unit, source: .statistical)
            let difference = live.value - middle
            guard difference.isFinite else { return nil }
            let spread = scalar(difference, id: "baseline.delta.\(signal.command)", title: "Разность с медианой · \(signal.title)",
                                unit: signal.unit, stamp: live.stamp, source: .calculated)
            return MonitoringValue(value: difference, stamp: live.stamp, validUntil: live.validUntil, evidence: live.evidence + baseline.evidence + spread.evidence)
        case .baselineMAD(let signal):
            guard let bucket, let mad = baseline.info(.init(signal: signal, bucket: bucket)).medianAbsoluteDeviation else { return nil }
            return scalar(mad, id: "baseline.mad.\(signal.command)", title: "Медианное отклонение · \(signal.title)",
                          unit: signal.unit, source: .statistical)
        case .constant(let number):
            return number.isFinite ? MonitoringValue(value: number, stamp: nil, evidence: []) : nil
        case .thermalLimit(let limit, let offset):
            let baseKey = "limit.\(limit.rawValue).0.0"
            let configured = switch limit {
            case .operating: frame.thermalThresholds.operating
            case .warning: frame.thermalThresholds.warning
            case .critical: frame.thermalThresholds.critical
            }
            let effective = (heldLimits[baseKey] ?? Double(configured)) + offset
            guard effective.isFinite else { return nil }
            return scalar(effective, id: "limit.\(limit.rawValue).\(offset)", title: "Порог пользователя",
                          unit: "°C", source: .configured)
        case .witnessedRuntime:
            guard let context, context.witnessed,
                  let runtime = fresh(.runTime, maximumAge: 30), let seconds = runtime.value,
                  (0..<65_535).contains(seconds), seconds.isFinite else { return nil }
            let elapsed = frame.monotonic - context.observedSince
            guard elapsed >= 0, abs(elapsed - seconds) <= 35 else { return nil }
            return scalar(seconds, id: "witnessed.runtime", title: "Время работы при наблюдавшемся запуске",
                          unit: "с", stamp: runtime.monotonic, date: runtime.timestamp,
                          validUntil: runtime.monotonic + 30, source: .context)
        case .initialCoolant:
            guard let context, context.witnessed, let coolant = context.initialCoolant else { return nil }
            return scalar(coolant, id: "witnessed.initial.coolant", title: "ОЖ при наблюдавшемся запуске",
                          unit: "°C", source: .context)
        case .adapterVoltageReference(let age):
            guard let offset = frame.adapterVoltageOffset, offset.isFinite,
                  let voltage = value(.reading(.adapterVoltage, maximumAge: age)),
                  (voltage.value + offset).isFinite else { return nil }
            return scalar(voltage.value + offset, id: "adapter.voltage.reference",
                          title: "Напряжение адаптера с поправкой пользователя", unit: "В",
                          stamp: voltage.stamp, date: voltage.evidence.first?.observedAt, validUntil: voltage.validUntil, source: .calculated)
        }
    }

    func truth(_ condition: MonitoringCondition) -> MonitoringTruth {
        switch condition {
        case .always(let state):
            return MonitoringTruth(value: state)
        case .all(let children):
            return .combining(children.map(truth), all: true)
        case .any(let children):
            return .combining(children.map(truth), all: false)
        case .compare(let lhs, let comparison, let rhs):
            guard let lhs = value(lhs), let rhs = value(rhs) else { return MonitoringTruth(value: nil) }
            return MonitoringTruth(value: comparison.test(lhs.value, rhs.value),
                                   stamp: [lhs.stamp, rhs.stamp].compactMap { $0 }.min(),
                                   validUntil: [lhs.validUntil, rhs.validUntil].compactMap { $0 }.min(),
                                   evidence: lhs.evidence + rhs.evidence)
        case .available(let metric):
            let metric = value(metric)
            return MonitoringTruth(value: metric.map { _ in true }, stamp: metric?.stamp, validUntil: metric?.validUntil,
                                   evidence: metric?.evidence ?? [])
        case .regimes(let accepted):
            guard regime != .unknown else { return MonitoringTruth(value: nil) }
            return MonitoringTruth(value: accepted.contains(regime))
        case .closedLoop:
            guard let reading = fresh(.fuelStatus, maximumAge: 8), reading.bytes.count == 2,
                  reading.bytes[1] == 0, [1, 2, 4, 8, 16].contains(reading.bytes[0]) else {
                return MonitoringTruth(value: nil)
            }
            let evidence = scalar(Double(reading.bytes[0]), id: "0103.A", title: DriveSignal.fuelStatus.title,
                                  unit: "", stamp: reading.monotonic, date: reading.timestamp, source: .ecu).evidence
            return MonitoringTruth(value: reading.bytes[0] == 2, stamp: reading.monotonic,
                                   validUntil: reading.monotonic + 8, evidence: evidence)
        case .witnessedColdStart:
            return MonitoringTruth(value: context?.witnessedColdStart)
        case .reachedOperating:
            return MonitoringTruth(value: context?.reachedOperating)
        case .readingsNear(let a, let b, let maximumSeparation, let maximumAge):
            guard let a = fresh(a, maximumAge: maximumAge), let b = fresh(b, maximumAge: maximumAge) else {
                return MonitoringTruth(value: nil)
            }
            return MonitoringTruth(value: abs(a.monotonic - b.monotonic) <= maximumSeparation,
                                   stamp: min(a.monotonic, b.monotonic),
                                   validUntil: min(a.monotonic, b.monotonic) + maximumAge)
        }
    }

    private func arithmetic(_ lhs: MonitoringMetric, _ rhs: MonitoringMetric,
                            operation: (Double, Double) -> Double) -> MonitoringValue? {
        guard let lhs = value(lhs), let rhs = value(rhs) else { return nil }
        let number = operation(lhs.value, rhs.value)
        guard number.isFinite else { return nil }
        return MonitoringValue(value: number, stamp: [lhs.stamp, rhs.stamp].compactMap { $0 }.min(),
                               validUntil: [lhs.validUntil, rhs.validUntil].compactMap { $0 }.min(),
                               evidence: lhs.evidence + rhs.evidence)
    }

    private func aggregate(_ window: MonitoringWindow) -> MonitoringValue? {
        guard window.duration.isFinite, window.duration > 0, window.maximumGap.isFinite, window.maximumGap > 0,
              window.minimumSpan.isFinite, window.minimumSpan >= 0,
              let current = fresh(window.signal, maximumAge: window.maximumAge),
              let history = history[window.signal], history.last?.monotonic == current.monotonic
        else { return nil }

        guard !window.closedLoopOnly || closedLoopSince != nil else { return nil }
        let scopeStart: Double
        switch window.scope {
        case .regime: scopeStart = regimeSince
        case .continuousRun:
            guard let context else { return nil }
            scopeStart = context.observedSince
        }
        let cutoff = max(frame.monotonic - window.duration, scopeStart,
                         window.closedLoopOnly ? (closedLoopSince ?? frame.monotonic) : scopeStart)
        let samples = history.drop(while: { $0.monotonic < cutoff })
        guard samples.count >= max(window.minimumSamples, 1), let first = samples.first, let last = samples.last,
              last.monotonic - first.monotonic >= window.minimumSpan,
              !zip(samples, samples.dropFirst()).contains(where: { $1.monotonic - $0.monotonic > window.maximumGap })
        else { return nil }
        let numbers = samples.compactMap(\.value)
        guard numbers.count == samples.count else { return nil }
        let number: Double?
        switch window.aggregate {
        case .average: number = numbers.reduce(0, +) / Double(numbers.count)
        case .minimum: number = numbers.min()
        case .maximum: number = numbers.max()
        case .median: number = MonitoringBaseline.median(numbers)
        case .spread: number = numbers.max().flatMap { high in numbers.min().map { high - $0 } }
        }
        guard let number, number.isFinite else { return nil }
        return scalar(number, id: "\(window.aggregate.rawValue).\(window.signal.command).\(window.duration)",
                      title: "\(window.aggregate.title) · \(window.signal.title)", unit: window.signal.unit,
                      stamp: last.monotonic, date: last.timestamp, validUntil: last.monotonic + window.maximumAge, source: .calculated)
    }

    private func scalar(_ number: Double, id: String, title: String, unit: String, stamp: Double? = nil,
                        date: Date? = nil, validUntil: Double? = nil, source: MonitoringEvidence.Source) -> MonitoringValue {
        MonitoringValue(value: number, stamp: stamp, validUntil: validUntil, evidence: [
            MonitoringEvidence(id: id, title: title, value: number, unit: unit, observedAt: date, source: source),
        ])
    }
}
