import CarGaugeCore
import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func reading(_ signal: DriveSignal, _ value: Double?, time: Double, bytes: [UInt8] = [],
                     quality: DriveReading.Quality = .received) -> DriveReading {
    DriveReading(signal: signal, value: value, bytes: bytes, timestamp: epoch.addingTimeInterval(time),
                 monotonic: time, quality: quality)
}

private func frame(_ time: Double, coolant: Double? = 88, rpm: Double? = 820, speed: Double? = 0,
                   ambient: Double? = 20, stamp: Double? = nil, trip: Int64? = 1, witnessed: Bool = false,
                   runtime: Double? = nil, knownDTCs: Bool = true, dtcs: Set<String> = [],
                   thresholds: ThermalThresholds = .standard, fuelSystem: [UInt8] = [2, 0],
                   extra: [DriveSignal: DriveReading] = [:], offset: Double? = nil) -> MonitoringFrame {
    let sampleTime = stamp ?? time
    var readings: [DriveSignal: DriveReading] = [
        .load: reading(.load, 25, time: sampleTime), .map: reading(.map, 35, time: sampleTime),
        .fuelStatus: reading(.fuelStatus, fuelSystem.first.map(Double.init), time: sampleTime, bytes: fuelSystem),
        .throttle: reading(.throttle, 12, time: sampleTime),
    ]
    for (signal, value) in [(DriveSignal.coolant, coolant), (.rpm, rpm), (.speed, speed), (.ambient, ambient),
                            (.runTime, runtime)] {
        if let value { readings[signal] = reading(signal, value, time: sampleTime) }
    }
    readings.merge(extra, uniquingKeysWith: { _, later in later })
    return MonitoringFrame(timestamp: epoch.addingTimeInterval(time), monotonic: time, readings: readings,
                           tripID: trip, engineStartObserved: witnessed, activeDTCs: dtcs,
                           thermalThresholds: thresholds, dtcCoverageKnown: knownDTCs, adapterVoltageOffset: offset)
}

private func state(_ update: MonitoringUpdate, _ id: String) -> MonitoringRuleResult? {
    update.results.first { $0.ruleID == id }
}

@Test func monitoringUsesOnlyUserTemperatureWarningsByDefault() {
    let profile = MonitoringProfile.g4fc
    #expect(profile.rules.filter { $0.enabledByDefault && $0.opensIssue }.map(\.id).sorted()
            == ["coolant.critical", "coolant.warning"])
    #expect(profile.rules.allSatisfy { $0.version > 0 && !$0.sourceURL.isEmpty &&
        !$0.applicability.isEmpty && !$0.rationale.isEmpty && !$0.limitations.isEmpty })
    #expect(!profile.rules.contains { $0.origin == .oem })
}

@Test func monitoringThresholdDwellCorrelationAndSeverityEscalation() throws {
    var engine = MonitoringEngine()
    #expect(state(engine.evaluate(frame(0, coolant: 106)), "coolant.warning")?.state == .deviation)
    #expect(engine.evaluate(frame(4, coolant: 106)).events.isEmpty)
    let warning = try #require(engine.evaluate(frame(5, coolant: 106, dtcs: ["P0128", "P0300"])).events.first)
    #expect(warning.severity == .warning)
    #expect(warning.kind == .problem)
    #expect(warning.shouldNotify)
    #expect(warning.relatedDTCs == ["P0128"])
    let critical = try #require(engine.evaluate(frame(6, coolant: 116)).events.first)
    #expect(critical.severity == .critical)
    #expect(critical.correlationID == warning.correlationID)
    #expect(critical.issueID != warning.issueID)
    #expect(critical.shouldNotify)
    #expect(engine.evaluate(frame(7, coolant: 119)).events.isEmpty)
    #expect(engine.checkpoint.openIssues.count == 2)
}

@Test func monitoringCachesCannotMatureOrClearAProblemDuringMissingData() throws {
    var engine = MonitoringEngine()
    _ = engine.evaluate(frame(0, coolant: 106))
    #expect(engine.evaluate(frame(5, coolant: 106, stamp: 0)).events.isEmpty)
    #expect(state(engine.evaluate(frame(6, coolant: nil)), "coolant.warning")?.state == .insufficientData)
    #expect(engine.evaluate(frame(7, coolant: 106)).events.isEmpty)
    let raised = try #require(engine.evaluate(frame(12, coolant: 106)).events.first)

    let absence = engine.evaluate(frame(13, coolant: nil))
    #expect(state(absence, "coolant.warning")?.issueID == raised.issueID)
    #expect(state(absence, "coolant.warning")?.state == .insufficientData)
    #expect(engine.checkpoint.openIssues.map(\.issueID) == [raised.issueID])
    engine.interrupt()

    for time in [20.0, 25, 30] {
        #expect(engine.evaluate(frame(time, coolant: 101)).events.isEmpty)
    }
    let recovered = try #require(engine.evaluate(frame(35, coolant: 101)).events.first)
    #expect(recovered.kind == .recovery)
    #expect(recovered.duration == nil)
    #expect(recovered.issueID == raised.issueID)
    #expect(recovered.correlationID == raised.correlationID)
    #expect(!recovered.shouldNotify)
    #expect(engine.checkpoint.openIssues.isEmpty)
}

@Test func monitoringRestoresIssuesOverridesAndSuppressesRepeatedNotifications() throws {
    var engine = MonitoringEngine()
    engine.setEnabled(true, ruleID: "oxygen.b1s1")
    let raised = try #require(engine.evaluate(frame(0, coolant: 117)).events.first)
    let encoded = try JSONEncoder().encode(engine.checkpoint)
    let decoded = try JSONDecoder().decode(MonitoringCheckpoint.self, from: encoded)
    engine = MonitoringEngine(checkpoint: decoded)
    #expect(engine.checkpoint.enabledOverrides["oxygen.b1s1"] == true)
    #expect(engine.checkpoint.openIssues.first?.issueID == raised.issueID)
    let changed = try #require(ThermalThresholds(operating: 80, warning: 120, critical: 130))
    for time in stride(from: 1.0, through: 21.0, by: 5) {
        #expect(engine.evaluate(frame(time, coolant: 116, thresholds: changed)).events.isEmpty)
    }
    let laterEvents = [22.0, 27, 32, 37].flatMap { engine.evaluate(frame($0, coolant: 100)).events }
    let recovered = try #require(laterEvents.first { $0.ruleID == "coolant.critical" })
    #expect(recovered.kind == .recovery)
    #expect(recovered.issueID == raised.issueID)
    #expect(recovered.duration == nil)
    let again = try #require(engine.evaluate(frame(38, coolant: 118)).events.first)
    #expect(!again.shouldNotify)
    #expect(again.issueID != raised.issueID)

    engine.setEnabled(false, ruleID: "coolant.critical")
    let disabled = try #require(state(engine.evaluate(frame(39, coolant: 90)), "coolant.critical"))
    #expect(!disabled.enabled)
    #expect(disabled.state == .notApplicable)
    #expect(disabled.issueID == again.issueID)
}

private func rolling(_ aggregate: MonitoringAggregate, closedLoop: Bool = false) -> MonitoringMetric {
    .aggregate(.init(.rpm, aggregate, duration: 30, minimumSamples: 4, minimumSpan: 9,
                     maximumGap: 4, maximumAge: 5, closedLoopOnly: closedLoop))
}

private func observationRule(window: MonitoringMetric, closedLoop: Bool = false,
                             context: [MonitoringMetric] = []) -> MonitoringRule {
    MonitoringRule(id: "test.window", version: 2, title: "Контроль окна", severity: .info, origin: .engineering,
                   sourceURL: "fixture", applicability: "fixture", rationale: "fixture", possibleCauses: [],
                   limitations: "fixture", correlationKey: "test", opensIssue: false,
                   applicableWhen: closedLoop ? .closedLoop : .always(true),
                   trigger: .compare(window, .above, .constant(0)), recovery: .always(false),
                   minimumViolation: 0, minimumRecovery: 0, context: context)
}

@Test func monitoringRollupsOnlyCountDistinctFreshSamplesInOneMode() throws {
    let aggregates: [MonitoringMetric] = [.minimum, .maximum, .median, .spread].map { rolling($0) }
    var engine = MonitoringEngine(rules: [observationRule(window: rolling(.average), context: aggregates)])
    for time in [0.0, 3, 6] {
        let outcome = engine.evaluate(frame(time, rpm: 800, stamp: 0))
        #expect(state(outcome, "test.window")?.state == .insufficientData)
    }
    engine.interrupt()

    _ = engine.evaluate(frame(10, rpm: 800))
    _ = engine.evaluate(frame(13, rpm: 820))
    _ = engine.evaluate(frame(16, rpm: 840))
    let full = try #require(state(engine.evaluate(frame(19, rpm: 900)), "test.window"))
    #expect(full.state == .deviation)
    let values = Dictionary(uniqueKeysWithValues: full.evidence.map { ($0.id, $0.value) })
    #expect(values["average.010C.30.0"] == 840)
    #expect(values["minimum.010C.30.0"] == 800)
    #expect(values["maximum.010C.30.0"] == 900)
    #expect(values["median.010C.30.0"] == 830)
    #expect(values["spread.010C.30.0"] == 100)
    #expect(state(engine.evaluate(frame(20, rpm: 2000, speed: 40)), "test.window")?.state == .insufficientData)
}

@Test func monitoringClosedLoopAndAbsenceBreakRollingWindows() {
    var engine = MonitoringEngine(rules: [observationRule(window: rolling(.average, closedLoop: true), closedLoop: true)])
    for time in [0.0, 3, 6, 9] { _ = engine.evaluate(frame(time, fuelSystem: [4, 0])) }
    let changed = engine.evaluate(frame(12, fuelSystem: [2, 0]))
    #expect(state(changed, "test.window")?.state == .insufficientData)
    for time in [15.0, 18, 21] { _ = engine.evaluate(frame(time)) }
    #expect(state(engine.evaluate(frame(22)), "test.window")?.state == .deviation)
    #expect(state(engine.evaluate(frame(23, rpm: nil)), "test.window")?.state == .insufficientData)
    #expect(state(engine.evaluate(frame(24)), "test.window")?.state == .insufficientData)
}

@Test func monitoringDoesNotTreatALateConnectionAsObservedColdStart() {
    var engine = MonitoringEngine()
    engine.setEnabled(true, ruleID: "coolant.warmup")
    let late = engine.evaluate(frame(0, coolant: 45, ambient: 0, runtime: 1200))
    #expect(late.regime == .warmingUp)
    #expect(state(late, "coolant.warmup")?.state == .notApplicable)
    let tooLate = engine.evaluate(frame(5, coolant: 47, ambient: 0, witnessed: true, runtime: 1205))
    #expect(state(tooLate, "coolant.warmup")?.state == .notApplicable)
    #expect(tooLate.events.isEmpty)

    engine.interrupt()
    let cold = engine.evaluate(frame(10, coolant: 5, ambient: 0, witnessed: true, runtime: 0))
    #expect(cold.regime == .coldStart)
    for seconds in stride(from: 5.0, through: 895, by: 5) {
        _ = engine.evaluate(frame(10 + seconds, coolant: 60, ambient: 0, runtime: seconds))
    }
    let long = engine.evaluate(frame(910, coolant: 60, ambient: 0, runtime: 900))
    #expect(state(long, "coolant.warmup")?.state == .deviation)
    #expect(long.events.isEmpty)
    engine.interrupt()
    let afterGap = engine.evaluate(frame(920, coolant: 60, ambient: 0, runtime: 910))
    #expect(state(afterGap, "coolant.warmup")?.state == .notApplicable)
}

@Test func monitoringBaselineNeedsReliableCoverageMultipleTripsAndRejectsFaultyTraining() throws {
    var engine = MonitoringEngine()
    for trip in 1...5 {
        for position in stride(from: 0.0, through: 90, by: 3) {
            _ = engine.evaluate(frame(Double(trip) * 100 + position, rpm: 800, trip: Int64(trip), knownDTCs: false))
        }
    }
    let pending = try #require(engine.evaluate(frame(600, rpm: 800, trip: 6)).baseline.first { $0.signal == .rpm })
    #expect(pending.sampleCount == 0)
    #expect(!pending.isSufficient)
    for trip in 6...10 {
        for position in stride(from: 0.0, through: 90, by: 3) {
            _ = engine.evaluate(frame(Double(trip) * 100 + position, rpm: 800, trip: Int64(trip)))
        }
    }
    let full = try #require(engine.evaluate(frame(1100, rpm: 800, trip: 11)).baseline.first { $0.signal == .rpm })
    #expect(full.isSufficient)
    #expect(full.median == 800)
    #expect(full.medianAbsoluteDeviation == 0)
    #expect(full.tripCount == 5)
    for position in stride(from: 3.0, through: 60, by: 3) {
        _ = engine.evaluate(frame(1100 + position, rpm: 2400, trip: 11))
    }
    let rejected = try #require(engine.evaluate(frame(1163, rpm: 2400, trip: 11)).baseline.first { $0.signal == .rpm })
    #expect(rejected.sampleCount == full.sampleCount)

    for position in stride(from: 3.0, through: 33, by: 3) {
        _ = engine.evaluate(frame(1200 + position, rpm: 800, trip: 12))
    }
    let accepted = try #require(engine.evaluate(frame(1236, rpm: 800, trip: 12)).baseline.first { $0.signal == .rpm })
    #expect(accepted.sampleCount > full.sampleCount)
    let fault = try #require(engine.evaluate(frame(1239, rpm: 800, trip: 12, dtcs: ["P0300"]))
        .baseline.first { $0.signal == .rpm })
    #expect(fault.sampleCount == full.sampleCount)
    let unrelatedTemperature = engine.evaluate(frame(1240, rpm: 800, ambient: -15, trip: 12))
    #expect(unrelatedTemperature.baseline.first { $0.signal == .rpm }?.isSufficient == false)
}

@Test func monitoringKeepsVoltageReferenceSeparateAndOxygenLimitationsInTheProfile() throws {
    var engine = MonitoringEngine()
    let sample = reading(.adapterVoltage, 12.1, time: 0)
    let report = engine.evaluate(frame(0, rpm: 0, extra: [.adapterVoltage: sample], offset: 0.4))
    #expect(report.regime == .ignitionOn)
    let voltage = try #require(state(report, "voltage.ignition"))
    #expect(voltage.state == .observing)
    #expect(voltage.evidence.first { $0.id == "ATRV" }?.value == 12.1)
    #expect(voltage.evidence.first { $0.id == "adapter.voltage.reference" }?.value == 12.5)
    #expect(voltage.evidence.first { $0.id == "adapter.voltage.reference" }?.source == .calculated)
    #expect(state(report, "voltage.running")?.state == .notApplicable)
    #expect(report.events.isEmpty)
    #expect(engine.rules.filter { $0.id.hasPrefix("oxygen.") }.allSatisfy { !$0.opensIssue })
}

@Test func monitoringTripFuelComparisonNeedsDistinctComparableCoveredObservations() throws {
    func trip(_ id: Int64, rate: Double = 8, coverage: Double = 0.9, load: Double = 25,
              modelKey: String = "speed-density@1/calibration@2") -> MonitoringTripFuelObservation {
        .init(tripID: id, averageLitresPer100km: rate, coverage: coverage, estimatedDistanceKM: 12,
              averageSpeedKPH: 40, averageLoadPercent: load, averageAmbientCelsius: 20,
              coveredRegime: .moving, modelKey: modelKey)
    }
    let current = trip(9, rate: 9)
    let prior = (1...5).map { trip(Int64($0)) }
    #expect(MonitoringFuelTrend.compare(current, references: Array(repeating: prior[0], count: 6)) == nil)
    #expect(MonitoringFuelTrend.compare(trip(9, coverage: 0.5), references: prior) == nil)
    let comparison = try #require(MonitoringFuelTrend.compare(current, references: prior + [
        trip(6, rate: 40, load: 80), trip(7, rate: 35, modelKey: "new-source"),
    ]))
    #expect(comparison.differenceLitresPer100km == 1)
    #expect(comparison.referenceTripCount == 5)
}

@Test func monitoringDwellDoesNotCrossASubFrameFreshnessGap() {
    var engine = MonitoringEngine()
    _ = engine.evaluate(frame(0, coolant: 108))
    // No full frame elapsed discontinuity at six seconds, but the previous signal expires at five.
    #expect(engine.evaluate(frame(6, coolant: 108)).events.isEmpty)
    #expect(engine.evaluate(frame(11, coolant: 108)).events.contains { $0.ruleID == "coolant.warning" })
}

@Test func monitoringObservationCarriesOnlyRelatedKnownCodes() {
    var engine = MonitoringEngine()
    let values = [DriveSignal.oxygen1: reading(.oxygen1, 0.8, time: 1),
                  DriveSignal.oxygen2: reading(.oxygen2, 0.4, time: 1)]
    let observed = engine.evaluate(frame(1, dtcs: ["P0133", "P0420", "P0300"], extra: values))
    #expect(state(observed, "oxygen.readings")?.relatedDTCs == ["P0133", "P0420"])
    #expect(state(observed, "oxygen.readings")?.state == .observing)
    #expect(observed.events.isEmpty)
}

@Test func monitoringCoolingDropAfterWarmupSurvivesRegimeBoundaryWithoutBridgingBLE() {
    var engine = MonitoringEngine()
    engine.setEnabled(true, ruleID: "coolant.drop")
    for time in stride(from: 0.0, through: 75, by: 5) {
        _ = engine.evaluate(frame(time, coolant: 92, speed: 40))
    }
    let crossing = engine.evaluate(frame(80, coolant: 73, speed: 40))
    #expect(crossing.regime == .warmingUp)
    #expect(state(crossing, "coolant.drop")?.state == .observing)
    for time in [85.0, 90] { _ = engine.evaluate(frame(time, coolant: 72, speed: 40)) }
    let drop = engine.evaluate(frame(95, coolant: 72, speed: 40))
    #expect(state(drop, "coolant.drop")?.state == .deviation)
    #expect(drop.events.isEmpty)
    let disconnection = engine.evaluate(frame(110, coolant: 72, speed: 40))
    #expect(state(disconnection, "coolant.drop")?.state == .notApplicable)
}

@Test func monitoringBaselineExcludesCachedReadingsFromPriorFuelMode() {
    var engine = MonitoringEngine()
    for time in stride(from: 0.0, through: 18, by: 3) {
        _ = engine.evaluate(frame(time, fuelSystem: [4, 0],
                                 extra: [.oxygen1: reading(.oxygen1, 0.8, time: time)]))
    }
    let closed = engine.evaluate(frame(21, fuelSystem: [2, 0],
                                      extra: [.oxygen1: reading(.oxygen1, 0.8, time: 18)]))
    #expect(closed.baseline.first { $0.signal == .oxygen1 }?.sampleCount == 0)
    let resampled = engine.evaluate(frame(24, fuelSystem: [2, 0],
                                         extra: [.oxygen1: reading(.oxygen1, 0.8, time: 24)]))
    #expect(resampled.baseline.first { $0.signal == .oxygen1 }?.sampleCount == 1)
}
