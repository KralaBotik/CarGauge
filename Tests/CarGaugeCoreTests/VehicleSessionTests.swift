import CarGaugeCore
import Foundation
import Testing

@Test func rememberedAdapterWinsOnColdLaunchAndRetriesAreBounded() {
    #expect(VehicleSessionPolicy.initialSource(hasSavedAdapter: true, launchesSimulator: false) == .vehicle)
    #expect(VehicleSessionPolicy.initialSource(hasSavedAdapter: true, launchesSimulator: true) == .simulator)
    #expect(VehicleSessionPolicy.initialSource(hasSavedAdapter: false, launchesSimulator: false) == .simulator)
    var budget = VehicleRetryBudget()
    let delays = (0..<5).map { _ in budget.nextDelay(inForeground: true) }
    #expect(delays == [1, 2, 4, 8, nil])
    var backgroundBudget = VehicleRetryBudget()
    let backgroundDelay = backgroundBudget.nextDelay(inForeground: false)
    #expect(backgroundDelay == nil)
}

@Test func shortPartialRecoveryDoesNotRenewTheRetryBudget() {
    var budget = VehicleRetryBudget()
    let first = budget.nextDelay(inForeground: true)
    for _ in 0..<9 { budget.didCompleteCycle() }
    let second = budget.nextDelay(inForeground: true)
    for _ in 0..<10 { budget.didCompleteCycle() }
    let renewed = budget.nextDelay(inForeground: true)
    #expect(first == 1)
    #expect(second == 2)
    #expect(renewed == 1)
}

@Test func parkingDependsOnContinuousFreshZeroRPMFollowingMotion() {
    let start = Date(timeIntervalSince1970: 1_000)
    var monitor = EngineIdleMonitor()
    func sample(_ rpm: Double, at offset: Double) -> Bool {
        let now = start.addingTimeInterval(offset)
        return monitor.shouldPark(after: Reading(rpm, at: now), at: now)
    }
    #expect(!sample(0, at: 0))
    #expect(!sample(0, at: 16))
    #expect(!sample(900, at: 17))
    #expect(!sample(0, at: 18))
    #expect(!sample(0, at: 20))
    let parkedOnStaleSample = monitor.shouldPark(after: Reading(0, at: start), at: start.addingTimeInterval(21))
    #expect(!parkedOnStaleSample)
    #expect(!sample(.nan, at: 22))
    #expect(!sample(0, at: 25))
    #expect(!sample(0, at: 30)) // Five seconds without samples breaks the series.
    for time in stride(from: 33.0, through: 42.0, by: 3) { #expect(!sample(0, at: time)) }
    #expect(sample(0, at: 45))
}

@Test func promptCompletesOnlyAtTheTerminatorAndDetectsTrailingPayload() throws {
    var buffer = ELMPromptBuffer()
    #expect(try buffer.append(Data("410".utf8)).isEmpty)
    #expect(try buffer.append(Data("57B\r".utf8)).isEmpty)
    #expect(try buffer.append(Data(">\r\n".utf8)) == ["41057B\r"])
    #expect(!buffer.hasPartialPayload)
    buffer.reset()
    #expect(try buffer.append(Data("41057B>410".utf8)) == ["41057B"])
    #expect(buffer.hasPartialPayload)
}

@MainActor
@Test func rejectedSamplesAndTimeoutDoNotProduceReadings() async throws {
    for (scenario, expected) in [(SimulationScenario.missingCoolant, OBDError.noData),
                                 (.invalidCoolant, .malformedResponse), (.hangingAdapter, .timeout)] {
        let transport = SimulatedTransport(scenario: scenario, latency: .zero)
        try await transport.connect()
        let client = ELM327Client(transport: transport)
        try await client.initialize()
        #expect(try await client.readCoolant().value == 20)
        if scenario != .hangingAdapter { #expect(try await client.readCoolant().value == 22) }
        await #expect(throws: expected) { try await client.readCoolant() }
        if scenario == .hangingAdapter {
            await #expect(throws: OBDError.disconnected) { try await client.readCoolant() }
        }
        transport.disconnect()
    }
}

@MainActor
@Test func initializedCoolantDoesNotTriggerAnExtraCommandAndSequencesDoNotOverlap() async throws {
    let transport = PausedInitialization()
    let client = ELM327Client(transport: transport)
    let initialization = Task { try await client.initialize() }
    var starts = transport.started.makeAsyncIterator()
    _ = await starts.next()
    await #expect(throws: OBDError.busy) { try await client.readCoolant() }
    await #expect(throws: OBDError.busy) {
        try await client.readSupplementary(source: .vehicle, coolant: Reading(80, at: Date()))
    }
    transport.continueInitialization()
    try await initialization.value
    #expect(try await client.readCoolant().value == 83)
    #expect(transport.coolantRequests == 1)
    #expect(try await client.readCoolant().value == 83)
    #expect(transport.coolantRequests == 2)
}

@MainActor private final class PausedInitialization: OBDTransport {
    private let signal = AsyncStream<Void>.makeStream()
    private var pause: CheckedContinuation<Void, Never>?
    private(set) var coolantRequests = 0
    var started: AsyncStream<Void> { signal.stream }

    func connect() async throws {}
    func disconnect() {}

    func continueInitialization() {
        pause?.resume()
        pause = nil
    }

    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        switch command {
        case "ATZ":
            await withCheckedContinuation {
                pause = $0
                signal.continuation.yield(())
            }
            return "ELM327 v2.3"
        case "0105":
            coolantRequests += 1
            return "41057B"
        default:
            return "OK"
        }
    }
}
