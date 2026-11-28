@testable import CarGaugeCore
import Foundation
import Testing

private func reading(_ signal: DriveSignal, _ value: Double?, at time: Double = 10,
                     bytes: [UInt8] = [], date: Double? = nil) -> DriveReading {
    DriveReading(signal: signal, value: value, bytes: bytes,
                 timestamp: Date(timeIntervalSince1970: date ?? (100_000 + time)), monotonic: time)
}

private func inputs(map: Double = 30, intake: Double = 25, rpm: Double = 850) -> [DriveSignal: DriveReading] {
    [.map: reading(.map, map), .intake: reading(.intake, intake), .rpm: reading(.rpm, rpm),
     .fuelStatus: reading(.fuelStatus, 2, bytes: [2, 0])]
}

@Test func speedDensityAgreesWithIndependentSIReference() throws {
    let idle = try #require(SpeedDensity.estimate(readings: inputs(), at: 10, targetProfile: true))
    #expect(abs(idle.litresPerHour - 1.111243) < 0.000002)
    #expect(idle.litresPer100km(speed: 0) == nil)
    #expect(idle.litresPer100km(speed: nil) == nil)
    let moving = try #require(SpeedDensity.estimate(readings: inputs(map: 43, intake: 28, rpm: 2200),
                                                  at: 10, targetProfile: true, calibration: 1.25))
    #expect(abs(moving.baseLitresPerHour - 4.081427) < 0.000002)
    #expect(abs((moving.litresPer100km(speed: 60) ?? 0) - 8.5029725) < 0.000005)
}

@Test func fuelIsUnknownForUnprovenProfileOpenLoopAndStaleInputs() {
    #expect(SpeedDensity.estimate(readings: inputs(), at: 10, targetProfile: false) == nil)
    #expect(SpeedDensity.estimate(readings: inputs(), at: 13.001, targetProfile: true) == nil)
    #expect(SpeedDensity.estimate(readings: inputs(rpm: 0), at: 10, targetProfile: true) == nil)
    for status: [UInt8] in [[1, 0], [4, 0], [8, 0], [16, 0], [2, 4], [6, 0]] {
        var vector = inputs()
        vector[.fuelStatus] = reading(.fuelStatus, nil, bytes: status)
        #expect(SpeedDensity.estimate(readings: vector, at: 10, targetProfile: true) == nil)
    }
    var vector = inputs()
    vector[.commandedLambda] = reading(.commandedLambda, 0.85)
    #expect(SpeedDensity.estimate(readings: vector, at: 10, targetProfile: true) == nil)
    vector[.intake] = nil
    #expect(SpeedDensity.estimate(readings: vector, at: 10, targetProfile: true) == nil)
}

@Test func allReportedMaskBitsAndAdaptiveScheduleStayInsideTheProfile() {
    let expected: [[UInt8]] = [
        [0x01,0x03,0x04,0x05,0x06,0x07,0x0B,0x0C,0x0D,0x0E,0x0F,0x11,0x13,0x14,0x15,0x1C,0x1F,0x20],
        [0x21,0x2E,0x30,0x31,0x3C,0x40],
        [0x41,0x43,0x44,0x45,0x46]
    ]
    var plan = VehiclePollPlan()
    for (page, pids) in zip(OBDSupportPage.allCases, expected) {
        let mask = VehiclePollPlan.referenceMasks[page.base] ?? 0
        #expect(VehiclePollPlan.advertised(base: page.base, mask: mask) == pids)
        plan.record(page: page, bits: mask)
    }
    #expect(plan.isTargetProfile)
    var counts: [DriveSignal: Int] = [:]
    for time in 0...300 {
        let cycle = plan.next(at: Double(time), background: false)
        #expect(cycle.count <= 3)
        for signal in cycle { counts[signal, default: 0] += 1 }
    }
    #expect(Set(counts.keys) == Set(DriveSignal.extra.filter(plan.supports)))
    #expect(counts[.speed] == 301)
    #expect((counts[.ambient] ?? 0) < (counts[.map] ?? 0) / 10)
    #expect(counts[.ecuVoltage] == nil)
}

@Test func runTimeRequiresCoherentSamplesAndNeverProvesRemoteStart() {
    var state = EngineStartEvidence()
    let a = reading(.runTime, 73, at: 10)
    #expect(state.observe(a, rpm: reading(.rpm, 850, at: 10)) == nil)
    let b = reading(.runTime, 81, at: 18)
    #expect(state.observe(b, rpm: reading(.rpm, 850, at: 18)) == a.timestamp.addingTimeInterval(-73))
    #expect(state.observe(reading(.runTime, 3, at: 26), rpm: reading(.rpm, 900, at: 26)) == nil)
    #expect(state.observe(reading(.runTime, 65535, at: 35), rpm: reading(.rpm, 900, at: 35)) == nil)
    let c = reading(.runTime, 313, at: 40)
    #expect(state.observe(c, rpm: reading(.rpm, 850, at: 40)) == nil)
    #expect(state.observe(reading(.runTime, 321, at: 48, date: 42), rpm: reading(.rpm, 850, at: 48)) == nil)
}

private func frame(_ tick: Double, speed: Double? = 36, rpm: Double? = 850, rate: Double? = 3.6,
                   wall: Double? = nil, duplicate: Bool = false) -> TripFrame {
    let sample = reading(.coolant, 88, at: tick, bytes: [128], date: wall)
    return TripFrame(timestamp: sample.timestamp, monotonic: tick, readings: duplicate ? [sample, sample] : [sample],
                     rpm: rpm, speed: speed, fuel: rate.map { FuelRate(litresPerHour: $0, baseLitresPerHour: $0, calibration: 1) })
}

@Test func integrationUsesOnlyMonotonicCommonCoverageAndSupportsIdle() throws {
    let interval = try #require(TripInterval.between(frame(10, speed: 60, rate: 3, wall: 1000),
                                                     frame(12, speed: 120, rate: 5, wall: 500)))
    #expect(interval.observedSeconds == 2)
    #expect(interval.distanceKm == 0.05)
    #expect(abs((interval.litres ?? 0) - (8.0 / 3600)) < 1e-12)
    let idle = try #require(TripInterval.between(frame(12, speed: 0), frame(18, speed: 0)))
    #expect(idle.distanceKm == 0)
    #expect(idle.idleSeconds == 6)
    #expect(idle.idleLitres == idle.litres)
    #expect(TripInterval.between(frame(12), frame(18.001)) == nil)
    #expect(TripInterval.between(frame(12), frame(12)) == nil)
    #expect(TripInterval.between(frame(12), frame(14, rpm: 0))?.litres == nil)
    #expect(TripInterval.between(frame(12), frame(14, speed: nil))?.pairedLitres == nil)
    #expect(TripInterval.between(frame(12), frame(14, rate: nil))?.litres == nil)
}

@Test func sqliteCommitsFrameAndBothTotalsTogetherAndSurvivesReopen() async throws {
    let owner = UUID()
    let root = FileManager.default.temporaryDirectory.appending(path: owner.uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "history.sqlite")
    do {
        let database = TelemetryArchive(url: url)
        try await database.record(owner: owner, frame: frame(1))
        await #expect(throws: (any Error).self) {
            try await database.record(owner: owner, frame: frame(2, duplicate: true))
        }
        try await database.record(owner: owner, frame: frame(3, wall: 99_999))
        try await database.record(owner: owner, frame: frame(3, wall: 99_999))
        try await database.record(owner: owner, frame: frame(10))
        try await database.record(owner: owner, frame: frame(12))
        let trip = try #require(await database.recentTrips().first)
        #expect(trip.observedEngineSeconds == 4)
        #expect(abs((trip.distanceKm ?? 0) - 0.04) < 1e-12)
        #expect(trip.finishReason == nil)
        let plot = try await database.plot(tripID: trip.id, channels: [.coolant])
        #expect(plot.gaps == 1)
        #expect(plot.series[.coolant]?.map(\.time) == [0, 2, 9, 11])
        #expect(plot.fuel.map(\.segment) == [1, 1, 2, 2])
        #expect(try await database.databaseSize() > 0)
    }
    let reopened = TelemetryArchive(url: url)
    let trip = try #require(await reopened.recentTrips().first)
    #expect(trip.finishReason == "app_interrupted")
    #expect(trip.observedEngineSeconds == 4)
    #expect(abs((trip.averageLitresPer100km ?? 0) - 10) < 1e-12)
    try await reopened.record(owner: UUID(), frame: frame(1))
    #expect(try await reopened.recentTrips().count == 2)
}

@Test func fullTankCalibrationUsesRawPredictionAndRequiresCoverage() async throws {
    let owner = UUID()
    let root = FileManager.default.temporaryDirectory.appending(path: owner.uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = TelemetryArchive(url: root.appending(path: "history.sqlite"))
    _ = try await database.startCalibration(odometer: 10, at: Date(timeIntervalSince1970: 100_000))
    for time in [1.0, 3, 5] { try await database.record(owner: owner, frame: frame(time)) }
    try await database.record(owner: owner, frame: frame(7, rpm: 0, rate: nil))
    let end = Date(timeIntervalSince1970: 100_008)
    await #expect(throws: FuelCalibrationError.coverage) {
        try await database.finishCalibration(odometer: 11, litres: 0.008, at: end)
    }
    let calibration = try await database.finishCalibration(odometer: 10.04, litres: 0.008, at: end)
    #expect(calibration.matchedFills == 1)
    #expect(abs(calibration.factor - 2) < 1e-12)
    #expect(calibration.initialOdometer == 10.04)
    #expect(abs((try await database.recentTrips().first?.litres ?? 0) - 0.004) < 1e-12)
}
