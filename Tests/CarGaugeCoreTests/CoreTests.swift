import CarGaugeCore
import Foundation
import Testing

@Test func decodesMode01AndAdapterVoltage() throws {
    #expect(try OBDDecoder.decode(.coolant, response: "01 05\rSEARCHING...\r41 05 7B\r>") == 83)
    #expect(try OBDDecoder.decode(.coolant, response: "410500\r>") == -40)
    #expect(try OBDDecoder.decode(.rpm, response: "41 0C 1A F9\r>") == 1726.25)
    #expect(try OBDDecoder.decode(.moduleVoltage, response: "41423778") == 14.2)
    #expect(try OBDDecoder.adapterVoltage("ATRV\r14.1v\r>") == 14.1)
}

@Test func rejectsWrongTruncatedAndConflictingReplies() throws {
    #expect(throws: OBDError.noData) { try OBDDecoder.decode(.coolant, response: "NO DATA\r>") }
    #expect(throws: OBDError.unsupported) { try OBDDecoder.decode(.coolant, response: "?\r>") }
    #expect(throws: OBDError.adapter("CANERROR")) { try OBDDecoder.decode(.coolant, response: "CAN ERROR") }
    for reply in ["4105", "4105+1", "41057B00", "410C7B", "7E80341057B", "41057B\r410C0000"] {
        #expect(throws: OBDError.malformedResponse) { try OBDDecoder.decode(.coolant, response: reply) }
    }
    #expect(throws: OBDError.ambiguousResponse) { try OBDDecoder.decode(.coolant, response: "41057B\r41057C") }
    #expect(try OBDDecoder.decode(.coolant, response: "41057B\r41057B") == 83)
    #expect(throws: OBDError.malformedResponse) { try OBDDecoder.adapterVoltage("NaNV") }
}

@Test func framesFragmentedNotificationsAndBoundsMemory() throws {
    var buffer = ELMPromptBuffer(limit: 12)
    #expect(try buffer.append(Data("410".utf8)).isEmpty)
    #expect(try buffer.append(Data("57B\r".utf8)).isEmpty)
    #expect(try buffer.append(Data(">OK\r>5".utf8)) == ["41057B\r", "OK\r"])
    #expect(try buffer.append(Data(">".utf8)) == ["5"])
    #expect(throws: OBDError.bufferOverflow) { try buffer.append(Data(repeating: 65, count: 13)) }
    #expect(try buffer.append(Data("OK>".utf8)) == ["OK"])
    #expect(throws: OBDError.malformedResponse) { try buffer.append(Data([255, 62])) }
}

@Test func staleReadingsDoNotClearHysteresis() {
    let now = Date(timeIntervalSince1970: 100)
    var monitor = OverheatMonitor()
    #expect(monitor.update(Reading(105, at: now), at: now) == .warning)
    #expect(monitor.update(Reading(104, at: now), at: now) == .warning)
    #expect(monitor.update(Reading(115, at: now), at: now) == .critical)
    #expect(monitor.update(Reading(113, at: now), at: now) == .critical)
    #expect(monitor.update(nil, at: now) == .critical)
    #expect(monitor.update(Reading(90, at: now - 5), at: now) == .critical)
    #expect(monitor.update(Reading(112, at: now), at: now) == .warning)
    #expect(monitor.update(Reading(102, at: now), at: now) == .normal)
    #expect(!Reading(0, at: now + 2).isFresh(at: now))
    #expect(Reading(0, at: now).isFresh(at: now))
}

@Test func historyBoundsTimeAndCount() {
    var history = WarmupHistory(capacity: 2, duration: 5)
    let now = Date(timeIntervalSince1970: 100)
    for time in [0.0, 1, 2, 2] {
        history.append(Reading(time, at: now + time))
    }
    #expect(history.readings.map(\.value) == [1, 2])
    history.append(Reading(8, at: now + 8))
    #expect(history.readings.map(\.value) == [8])
}

@Test func reconnectBackoffCapsAndResets() {
    var backoff = ReconnectBackoff()
    #expect((0..<8).map { _ in backoff.nextDelay() } == [1, 2, 4, 8, 16, 30, 30, 30])
    backoff.reset()
    #expect(backoff.nextDelay() == 1)
}

@MainActor
@Test func simulatorWarmupAndVoltageFallback() async throws {
    for scenario in [SimulationScenario.warmup, .noVoltagePID] {
        let transport = SimulatedTransport(scenario: scenario, latency: .zero)
        let client = ELM327Client(transport: transport)
        try await transport.connect()
        try await client.initialize()
        let first = try await client.readCoolant()
        let snapshot = try await client.readSupplementary(source: .simulator, coolant: first)
        let second = try await client.readCoolant()
        #expect(first.value == 20)
        #expect(second.value > first.value)
        #expect(snapshot.rpm?.value == 1385)
        #expect(snapshot.source == .simulator)
        #expect(snapshot.voltageSource == (scenario == .warmup ? .ecu : .adapter))
        #expect(snapshot.voltage?.value == (scenario == .warmup ? 14.2 : 14.1))
        transport.disconnect()
        await #expect(throws: OBDError.disconnected) { try await client.readCoolant() }
    }
}

@MainActor
@Test func simulatorOverheatAndDisconnect() async throws {
    let hot = SimulatedTransport(scenario: .overheat, latency: .zero)
    try await hot.connect()
    let client = ELM327Client(transport: hot)
    try await client.initialize()
    var monitor = OverheatMonitor()
    var levels: [ThermalLevel] = []
    for _ in 0..<10 {
        let reading = try await client.readCoolant()
        levels.append(monitor.update(reading, at: Date()))
    }
    #expect(levels.contains(.warning))
    #expect(levels.last == .critical)
    let failing = SimulatedTransport(scenario: .disconnect, latency: .zero)
    try await failing.connect()
    let failingClient = ELM327Client(transport: failing)
    try await failingClient.initialize()
    for _ in 0..<6 { _ = try await failingClient.readCoolant() }
    await #expect(throws: OBDError.disconnected) { try await failingClient.readCoolant() }
}

@MainActor private final class ScriptedTransport: OBDTransport {
    var commands: [String] = []
    var timeouts: [TimeInterval] = []
    var responses: [String: String] = [:]
    var timedOutCommands: Set<String> = []
    func connect() async throws {}
    func disconnect() {}
    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        commands.append(command)
        timeouts.append(timeout)
        if timedOutCommands.contains(command) { throw OBDError.timeout }
        return responses[command, default: "OK"]
    }
}

@MainActor
@Test func sessionConfiguresAdapterAndPrefersCoolant() async throws {
    let transport = ScriptedTransport()
    transport.responses = ["ATZ": "ATZ\rELM327 v2.3", "0105": "SEARCHING...41057B",
                           "010C": "NO DATA", "0142": "NO DATA", "ATRV": "14.1V"]
    let client = ELM327Client(transport: transport)
    try await client.initialize()
    #expect(transport.commands == ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0", "0105"])
    #expect(transport.timeouts.last == 15)
    let coolant = try await client.readCoolant()
    let first = try await client.readSupplementary(source: .vehicle, coolant: coolant)
    #expect(first.rpm == nil)
    #expect(first.voltageSource == .adapter)
    _ = try await client.readSupplementary(source: .vehicle, coolant: coolant)
    #expect(Array(transport.commands.suffix(5)) == ["0105", "010C", "0142", "ATRV", "ATRV"])
}

@MainActor
@Test func initStopsOnRejectedConfiguration() async throws {
    let transport = ScriptedTransport()
    transport.responses = ["ATZ": "ELM327 v2.3", "ATH0": "?"]
    let client = ELM327Client(transport: transport)
    await #expect(throws: OBDError.unsupported) { try await client.initialize() }
    #expect(transport.commands.last == "ATH0")
}

@MainActor
@Test func optionalBadRepliesLeaveCoolantAvailable() async throws {
    let transport = ScriptedTransport()
    transport.responses = ["ATZ": "ELM327 v2.3", "0105": "41057B", "010C": "410C13",
                           "0142": "41423778\r414236B0", "ATRV": "INVALID"]
    let client = ELM327Client(transport: transport)
    try await client.initialize()
    let coolant = try await client.readCoolant()
    let snapshot = try await client.readSupplementary(source: .vehicle, coolant: coolant)
    #expect(snapshot.coolant.value == 83)
    #expect(snapshot.rpm == nil)
    #expect(snapshot.voltage == nil)
    #expect(transport.commands.suffix(3) == ["010C", "0142", "ATRV"])
}

@MainActor
@Test func timedOutSimulatorRequiresReconnect() async throws {
    let transport = SimulatedTransport(latency: .milliseconds(1))
    try await transport.connect()
    await #expect(throws: OBDError.busy) { try await transport.connect() }
    await #expect(throws: OBDError.timeout) { try await transport.exchange("ATZ", timeout: 0) }
    await #expect(throws: OBDError.disconnected) { try await transport.exchange("ATZ", timeout: 1) }
    try await transport.connect()
    #expect(try await transport.exchange("ATZ", timeout: 1) == "ELM327 v2.3\r>")
}

@Test func temperaturesFollowConfiguredLimitsAndHysteresis() throws {
    let thresholds = try #require(ThermalThresholds(operating: 75, warning: 95, critical: 105))
    #expect(thresholds.state(at: 74, alert: .normal) == .warmingUp)
    #expect(thresholds.state(at: 75, alert: .normal) == .operating)
    #expect(thresholds.state(at: 95, alert: .normal) == .warning)
    #expect(thresholds.state(at: 105, alert: .normal) == .critical)
    #expect(thresholds.setting(.critical, to: 96) == nil)
    #expect(thresholds.range(for: .warning).upperBound == 101)
    #expect(try JSONDecoder().decode(ThermalThresholds.self, from: JSONEncoder().encode(thresholds)) == thresholds)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ThermalThresholds.self,
                                     from: Data(#"{"operating":75,"warning":105,"critical":95}"#.utf8))
    }

    let now = Date()
    var monitor = OverheatMonitor()
    monitor.apply(thresholds)
    #expect(monitor.update(Reading(106, at: now), at: now) == .critical)
    let cooling = Reading(103, at: now)
    #expect(thresholds.state(at: cooling.value, alert: monitor.update(cooling, at: now)) == .critical)
    #expect(monitor.update(Reading(101, at: now), at: now) == .warning)
}

@Test func graphDoesNotJoinAcrossFastReconnectOrMissingSamples() {
    let start = Date(timeIntervalSince1970: 100)
    var history = WarmupHistory(capacity: 4)
    history.append(Reading(30, at: start))
    history.append(Reading(31, at: start + 1))
    history.interrupt()
    history.append(Reading(34, at: start + 3))
    history.append(Reading(35, at: start + 4))
    #expect(history.points.map(\.segment) == [0, 0, 1, 1])
    history.append(Reading(45, at: start + 9))
    #expect(history.points.map(\.segment) == [0, 1, 1, 2])
}

@MainActor
@Test func ecuVoltageTimeoutFallsBackOnlyAfterANewHandshake() async throws {
    let responses = ["ATZ": "ELM327 v2.3", "0105": "41057B", "010C": "410C0C80", "ATRV": "14.1V"]
    var recovery = SupplementaryRecovery()

    let firstLink = ScriptedTransport()
    firstLink.responses = responses
    firstLink.timedOutCommands = ["0142"]
    let firstClient = ELM327Client(transport: firstLink)
    try await firstClient.initialize()
    let firstCoolant = try await firstClient.readCoolant()
    do {
        _ = try await firstClient.readSupplementary(source: .vehicle, coolant: firstCoolant)
        Issue.record("Expected to identify the ECU voltage timeout")
    } catch let timeout as SupplementaryTimeout {
        #expect(timeout == .ecuVoltage)
        #expect(timeout.sensor == .voltage)
        recovery.record(timeout)
    }
    #expect(firstLink.commands.suffix(2) == ["010C", "0142"])
    #expect(!firstLink.commands.contains("ATRV"))
    #expect(recovery.initialVoltageSource == .adapter)
    #expect(recovery.skippedSensors.isEmpty)
    firstLink.disconnect()

    let fallback = ScriptedTransport()
    fallback.responses = responses
    fallback.timedOutCommands = ["0142"]
    let fallbackClient = ELM327Client(transport: fallback)
    try await fallback.connect()
    try await fallbackClient.initialize(voltageSource: recovery.initialVoltageSource)
    let nextCoolant = try await fallbackClient.readCoolant()
    let recovered = try await fallbackClient.readSupplementary(source: .vehicle, coolant: nextCoolant,
                                                                skipping: recovery.skippedSensors)
    #expect(recovered.coolant.value == 83)
    #expect(recovered.rpm?.value == 800)
    #expect(recovered.voltage?.value == 14.1)
    #expect(recovered.voltageSource == .adapter)
    #expect(fallback.commands == ELM327Client.initializationCommands + ["0105", "010C", "ATRV"])

    fallback.timedOutCommands.insert("ATRV")
    do {
        _ = try await fallbackClient.readSupplementary(source: .vehicle, coolant: nextCoolant)
        Issue.record("Expected to identify the adapter voltage timeout")
    } catch let timeout as SupplementaryTimeout {
        #expect(timeout == .adapterVoltage)
        recovery.record(timeout)
    }
    #expect(recovery.skippedSensors == [.voltage])
    fallback.disconnect()

    let finalLink = ScriptedTransport()
    finalLink.responses = responses
    finalLink.timedOutCommands = ["0142", "ATRV"]
    let finalClient = ELM327Client(transport: finalLink)
    try await finalLink.connect()
    try await finalClient.initialize(voltageSource: recovery.initialVoltageSource)
    let lastCoolant = try await finalClient.readCoolant()
    let finalReading = try await finalClient.readSupplementary(source: .vehicle, coolant: lastCoolant,
                                                               skipping: recovery.skippedSensors)
    #expect(finalReading.coolant.value == 83)
    #expect(finalReading.rpm?.value == 800)
    #expect(finalReading.voltage == nil)
    #expect(finalLink.commands == ELM327Client.initializationCommands + ["0105", "010C"])
}

@Test func rpmTimeoutDoesNotChangeThePreferredVoltageRoute() {
    var recovery = SupplementaryRecovery()
    recovery.record(.rpm)
    #expect(recovery.skippedSensors == [.rpm])
    #expect(recovery.initialVoltageSource == .ecu)
}

@MainActor
@Test func unavailableFallbackVoltageIsNotPolledOnEveryCoolantCycle() async throws {
    let transport = ScriptedTransport()
    transport.responses = ["ATZ": "ELM327 v2.3", "0105": "41057B", "010C": "?",
                           "0142": "NO DATA", "ATRV": "NO DATA"]
    let client = ELM327Client(transport: transport)
    try await client.initialize()
    for _ in 0..<3 {
        let coolant = try await client.readCoolant()
        let snapshot = try await client.readSupplementary(source: .vehicle, coolant: coolant)
        #expect(snapshot.voltage == nil)
    }
    #expect(transport.commands.filter { $0 == "ATRV" }.count == 1)
}
