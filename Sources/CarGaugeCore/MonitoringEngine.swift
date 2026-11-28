import Foundation

public struct MonitoringEngine: Sendable {
    private struct Dwell: Sendable {
        enum Kind: Sendable { case trigger, recovery }
        let kind: Kind
        let since: Double
        var latestEvidence: Double
        var latestEvidenceExpiry: Double?
    }

    private struct RuleRuntime: Sendable {
        var dwell: Dwell?
        var continuousIssueSince: Double?

        mutating func advance(_ kind: Dwell.Kind, minimum: Double, time: Double, truth: MonitoringTruth) -> Bool {
            guard let stamp = truth.stamp, minimum.isFinite, minimum >= 0 else {
                dwell = nil
                return false
            }
            guard let current = dwell, current.kind == kind,
                  current.latestEvidenceExpiry.map({ stamp <= $0 }) ?? true else {
                dwell = Dwell(kind: kind, since: time, latestEvidence: stamp, latestEvidenceExpiry: truth.validUntil)
                return minimum == 0
            }
            guard stamp > current.latestEvidence else { return false }
            dwell?.latestEvidence = stamp
            dwell?.latestEvidenceExpiry = truth.validUntil
            return stamp - current.since >= minimum
        }
    }

    public let rules: [MonitoringRule]
    private var enabledOverrides: [String: Bool]
    private var open: [String: MonitoringEvent]
    private var notices: [String: MonitoringNotice]
    private var baseline: MonitoringBaseline

    private var runtime: [String: RuleRuntime] = [:]
    private var history: [DriveSignal: [DriveReading]] = [:]
    private var lastFrameTime: Double?
    private var lastTrip: Int64?
    private var run: MonitoringRunContext?
    private var bucketSince: Double?
    private var priorBucket: MonitoringBucket?
    private var lastLearned: [MonitoringBaselineKey: Double] = [:]
    private var excludedTrip: Int64?
    private var priorRegime: MonitoringRegime?
    private var regimeSince: Double?
    private var closedLoopSince: Double?

    public init(rules: [MonitoringRule] = MonitoringProfile.g4fc.rules, checkpoint: MonitoringCheckpoint? = nil) {
        var keys: Set<String> = []
        self.rules = rules.filter { keys.insert($0.key).inserted }.sorted {
            if $0.severity.priority != $1.severity.priority { return $0.severity.priority > $1.severity.priority }
            return $0.key < $1.key
        }
        let valid = checkpoint?.schemaVersion == 1 ? checkpoint : nil
        enabledOverrides = valid?.enabledOverrides ?? [:]
        open = Dictionary((valid?.openIssues ?? []).filter { $0.kind == .problem }.map {
            ("\($0.ruleID)@\($0.ruleVersion)", $0)
        }, uniquingKeysWith: { $0.occurredAt < $1.occurredAt ? $1 : $0 })
        notices = valid?.notices ?? [:]
        baseline = valid?.baseline ?? MonitoringBaseline()
    }

    public var checkpoint: MonitoringCheckpoint {
        MonitoringCheckpoint(schemaVersion: 1,
                             openIssues: open.values.sorted { $0.occurredAt < $1.occurredAt },
                             enabledOverrides: enabledOverrides, baseline: baseline, notices: notices)
    }

    public func isEnabled(_ rule: MonitoringRule) -> Bool { enabledOverrides[rule.id] ?? rule.enabledByDefault }

    public mutating func setEnabled(_ enabled: Bool, ruleID: String) {
        guard rules.contains(where: { $0.id == ruleID }) else { return }
        enabledOverrides[ruleID] = enabled
        for rule in rules where rule.id == ruleID { runtime[rule.key] = nil }
    }

    /// Clears only timing and observation evidence. Silence never closes an issue.
    public mutating func interrupt() {
        runtime = [:]
        history = [:]
        lastFrameTime = nil
        lastTrip = nil
        run = nil
        bucketSince = nil
        priorBucket = nil
        lastLearned = [:]
        priorRegime = nil
        regimeSince = nil
        closedLoopSince = nil
    }

    public mutating func evaluate(_ frame: MonitoringFrame) -> MonitoringUpdate {
        guard frame.monotonic.isFinite,
              frame.timestamp.timeIntervalSinceReferenceDate.isFinite else {
            interrupt()
            return MonitoringUpdate(regime: .unknown, results: rules.map {
                result($0, state: .insufficientData, evidence: [])
            }, events: [], baseline: [])
        }
        if let lastFrameTime, frame.monotonic < lastFrameTime || frame.monotonic - lastFrameTime > 6 {
            interrupt()
        }
        if let lastTrip, let trip = frame.tripID, trip != lastTrip { interrupt() }
        if let trip = frame.tripID { lastTrip = trip }
        lastFrameTime = frame.monotonic
        ingest(frame)
        updateRun(frame)
        let regime = classify(frame)
        if regime != priorRegime {
            priorRegime = regime
            regimeSince = frame.monotonic
        }
        if MonitoringEvaluation.fresh(.fuelStatus, frame: frame, maximumAge: 8)?.bytes == [2, 0] {
            if closedLoopSince == nil { closedLoopSince = frame.monotonic }
        } else {
            closedLoopSince = nil
        }
        let bucket = comparability(frame, regime: regime)
        if bucket != priorBucket {
            priorBucket = bucket
            bucketSince = bucket.map { _ in frame.monotonic }
        }

        let evaluator = MonitoringEvaluation(frame: frame, regime: regime, context: run, baseline: baseline,
                                             bucket: bucket, history: history, regimeSince: regimeSince ?? frame.monotonic,
                                             closedLoopSince: closedLoopSince)
        var results: [MonitoringRuleResult] = []
        var events: [MonitoringEvent] = []
        for rule in rules {
            let (status, event) = evaluate(rule: rule, using: evaluator)
            results.append(status)
            if let event { events.append(event) }
        }

        // Known problems invalidate the candidate training data from the whole sampled trip.
        if let trip = frame.tripID, !open.isEmpty || !frame.activeDTCs.isEmpty {
            if trip != excludedTrip {
                baseline.discard(trip: trip)
                excludedTrip = trip
            }
        } else if let trip = frame.tripID, let bucket, trip != excludedTrip, frame.dtcCoverageKnown,
                  bucketSince.map({ frame.monotonic - $0 >= 15 }) == true,
                  !results.contains(where: { $0.state == .deviation || $0.state == .problem }) {
            learn(evaluator, bucket: bucket, trip: trip)
        }
        return MonitoringUpdate(regime: regime, results: results, events: events, baseline: baseline.allInfo(in: bucket))
    }

    private mutating func evaluate(rule: MonitoringRule, using evaluator: MonitoringEvaluation)
        -> (MonitoringRuleResult, MonitoringEvent?) {
        let key = rule.key
        var state = runtime[key, default: RuleRuntime()]
        var evaluator = evaluator
        if let existing = open[key] {
            evaluator.heldLimits = Dictionary(existing.evidence.filter { $0.source == .configured }.map {
                ($0.id, $0.value)
            }, uniquingKeysWith: { _, later in later })
        }

        let relatedDTCs = Self.related(rule, frame: evaluator.frame)
        let applicable = evaluator.truth(rule.applicableWhen)
        let context = rule.context.compactMap(evaluator.value).flatMap(\.evidence)
        guard isEnabled(rule), applicable.value == true else {
            runtime[key] = nil
            let status: MonitoringState = isEnabled(rule) && applicable.value == nil ? .insufficientData : .notApplicable
            return (result(rule, state: status, evidence: applicable.evidence + context, relatedDTCs: relatedDTCs), nil)
        }

        defer { runtime[key] = state }
        let frame = evaluator.frame
        let trigger = evaluator.truth(rule.trigger)
        let recovery = evaluator.truth(rule.recovery)
        if let issue = open[key] {
            let evidence = applicable.evidence + recovery.evidence + context
            guard recovery.value != nil, trigger.value != nil else {
                state = RuleRuntime()
                return (result(rule, state: .insufficientData, evidence: evidence, relatedDTCs: relatedDTCs), nil)
            }
            if recovery.value == true {
                let truth = MonitoringTruth.combining([applicable, recovery], all: true)
                if state.advance(.recovery, minimum: rule.minimumRecovery, time: frame.monotonic, truth: truth) {
                    open[key] = nil
                    let duration = state.continuousIssueSince.map { frame.monotonic - $0 }
                    state = RuleRuntime()
                    let event = makeEvent(rule, using: evaluator, kind: .recovery, issueID: issue.issueID,
                                          correlationID: issue.correlationID, evidence: evidence,
                                          duration: duration, shouldNotify: false)
                    return (result(rule, state: .recovered, evidence: evidence, relatedDTCs: relatedDTCs), event)
                }
            } else {
                state.dwell = nil
            }
            return (result(rule, state: .problem, evidence: evidence, relatedDTCs: relatedDTCs), nil)
        }

        let evidence = applicable.evidence + trigger.evidence + context
        guard let triggered = trigger.value else {
            state = RuleRuntime()
            return (result(rule, state: .insufficientData, evidence: evidence, relatedDTCs: relatedDTCs), nil)
        }
        guard triggered else {
            state = RuleRuntime()
            return (result(rule, state: rule.opensIssue ? .normal : .observing, evidence: evidence, relatedDTCs: relatedDTCs), nil)
        }

        let truth = MonitoringTruth.combining([applicable, trigger], all: true)
        let matured = state.advance(.trigger, minimum: rule.minimumViolation, time: frame.monotonic, truth: truth)
        if !rule.opensIssue {
            // An experimental observation can display evidence but cannot enter the problem journal.
            return (result(rule, state: matured ? .deviation : .observing, evidence: evidence, relatedDTCs: relatedDTCs), nil)
        }
        guard matured else { return (result(rule, state: .deviation, evidence: evidence, relatedDTCs: relatedDTCs), nil) }

        let group = open.values.filter { $0.correlationKey == rule.correlationKey }
            .min { $0.occurredAt < $1.occurredAt }?.correlationID ?? UUID()
        let notify = wantsNotice(rule, at: frame.timestamp)
        let event = makeEvent(rule, using: evaluator, kind: .problem, issueID: UUID(),
                              correlationID: group, evidence: evidence, duration: nil, shouldNotify: notify)
        open[key] = event
        state = RuleRuntime(dwell: nil, continuousIssueSince: frame.monotonic)
        return (result(rule, state: .problem, evidence: evidence, relatedDTCs: relatedDTCs), event)
    }

    private func result(_ rule: MonitoringRule, state: MonitoringState,
                        evidence: [MonitoringEvidence], relatedDTCs: [String] = []) -> MonitoringRuleResult {
        MonitoringRuleResult(ruleID: rule.id, ruleVersion: rule.version, state: state,
                             issueID: open[rule.key]?.issueID, evidence: Self.unique(evidence), enabled: isEnabled(rule),
                             relatedDTCs: relatedDTCs)
    }

    private mutating func wantsNotice(_ rule: MonitoringRule, at date: Date) -> Bool {
        guard rule.severity != .info, rule.origin != .experimental, rule.origin != .individual else { return false }
        if let prior = notices[rule.correlationKey],
           date.timeIntervalSince(prior.occurredAt) < rule.notificationCooldown,
           rule.severity.priority <= prior.severity.priority { return false }
        notices[rule.correlationKey] = MonitoringNotice(occurredAt: date, severity: rule.severity)
        return true
    }

    private func makeEvent(_ rule: MonitoringRule, using evaluator: MonitoringEvaluation, kind: MonitoringEvent.Kind,
                           issueID: UUID, correlationID: UUID, evidence: [MonitoringEvidence], duration: Double?,
                           shouldNotify: Bool) -> MonitoringEvent {
        let frame = evaluator.frame
        return MonitoringEvent(id: UUID(), issueID: issueID, correlationID: correlationID, ruleID: rule.id,
                               ruleVersion: rule.version, kind: kind, occurredAt: frame.timestamp,
                               tripID: frame.tripID, duration: duration, severity: rule.severity,
                               regime: evaluator.regime, evidence: Self.unique(evidence),
                               relatedDTCs: Self.related(rule, frame: frame),
                               correlationKey: rule.correlationKey, shouldNotify: shouldNotify)
    }

    private static func related(_ rule: MonitoringRule, frame: MonitoringFrame) -> [String] {
        Set(frame.activeDTCs.map { $0.uppercased() }).intersection(rule.relevantDTCs).sorted()
    }

    private static func unique(_ evidence: [MonitoringEvidence]) -> [MonitoringEvidence] {
        var identifiers: Set<String> = []
        return evidence.filter { identifiers.insert($0.id).inserted }
    }

    private mutating func ingest(_ frame: MonitoringFrame) {
        for signal in Set(history.keys).union(frame.readings.keys) {
            guard let reading = MonitoringEvaluation.fresh(signal, frame: frame, maximumAge: 900),
                  reading.value?.isFinite == true else {
                history[signal] = nil
                continue
            }
            var buffer = history[signal, default: []]
            if let last = buffer.last, reading.monotonic <= last.monotonic { continue }
            buffer.append(reading)
            let expired = buffer.prefix { frame.monotonic - $0.monotonic > 900 }.count
            buffer.removeFirst(max(expired, buffer.count - 450))
            history[signal] = buffer
        }
    }

    private func current(_ signal: DriveSignal, at frame: MonitoringFrame, age: Double) -> Double? {
        guard let value = MonitoringEvaluation.fresh(signal, frame: frame, maximumAge: age)?.value,
              value.isFinite else { return nil }
        return value
    }

    private mutating func updateRun(_ frame: MonitoringFrame) {
        guard let rpm = current(.rpm, at: frame, age: 5), rpm > 0 else {
            run = nil
            return
        }
        if run == nil {
            let nearStart = current(.runTime, at: frame, age: 15).map { (0...15).contains($0) } ?? false
            run = MonitoringRunContext(observedSince: frame.monotonic, witnessed: frame.engineStartObserved && nearStart,
                                       initialCoolant: current(.coolant, at: frame, age: 5),
                                       initialAmbient: current(.ambient, at: frame, age: 75))
        }
        if let coolant = current(.coolant, at: frame, age: 5),
           coolant >= Double(frame.thermalThresholds.operating) {
            run?.reachedOperating = true
        }
    }

    private func classify(_ frame: MonitoringFrame) -> MonitoringRegime {
        guard let rpm = current(.rpm, at: frame, age: 5), rpm >= 0 else { return .unknown }
        if rpm == 0 { return .ignitionOn }
        guard let coolant = current(.coolant, at: frame, age: 5), let speed = current(.speed, at: frame, age: 6),
              speed >= 0 else { return .unknown }
        if coolant < Double(frame.thermalThresholds.operating) {
            if let run, run.witnessedColdStart == true, frame.monotonic - run.observedSince <= 120 {
                return .coldStart
            }
            return .warmingUp
        }
        if speed == 0 { return .warmIdle }
        let speedSamples = history[.speed, default: []].suffix(2)
        if let earlier = speedSamples.first, let later = speedSamples.last, let previous = earlier.value,
           later.monotonic - earlier.monotonic <= 5, previous - speed >= 3,
           let throttle = current(.relativeThrottle, at: frame, age: 15), throttle >= 0, throttle <= 2 {
            return .decelerationCandidate
        }
        if let load = current(.load, at: frame, age: 25), (65...100).contains(load) { return .higherLoad }
        return .moving
    }

    private func comparability(_ frame: MonitoringFrame, regime: MonitoringRegime) -> MonitoringBucket? {
        // Baseline sampling is intentionally narrower than the visible regime classifier.
        guard [.warmIdle, .moving, .higherLoad].contains(regime),
              let ambient = current(.ambient, at: frame, age: 75), (-40...80).contains(ambient),
              let load = current(.load, at: frame, age: 25), (0...100).contains(load),
              let speed = current(.speed, at: frame, age: 6), (0...255).contains(speed) else { return nil }
        return MonitoringBucket(regime: regime, ambientBand: Int((ambient / 10).rounded(.down)) * 10,
                                loadBand: Int(load / 20) * 20, speedBand: Int(speed / 20) * 20)
    }

    private mutating func learn(_ evaluator: MonitoringEvaluation, bucket: MonitoringBucket, trip: Int64) {
        for signal in MonitoringBaseline.signals {
            let key = MonitoringBaselineKey(signal: signal, bucket: bucket)
            guard let sample = evaluator.fresh(signal, maximumAge: min(signal.displayLifetime, 80)),
                  let value = sample.value, value.isFinite, let bucketSince, sample.monotonic >= bucketSince,
                  lastLearned[key].map({ sample.monotonic - $0 >= 12 }) ?? true else { continue }
            if [.shortTrim, .longTrim, .oxygen1, .oxygen2].contains(signal) {
                guard let closedLoopSince = evaluator.closedLoopSince, sample.monotonic >= closedLoopSince else { continue }
            }
            lastLearned[key] = sample.monotonic
            baseline.learn(key: key, trip: trip, value: value)
        }
    }
}
