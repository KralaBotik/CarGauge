import CarGaugeCore
import Foundation
import Testing

@Test func supportMasksDecodeFourBytesAndMapModeOneSensors() throws {
    let base = try OBDDecoder.supportMask(.pids01To20, response: "01 00\rSEARCHING...\r41 00 08 10 00 01\r410008100001\r>")
    #expect(base.bits == 0x0810_0001)
    #expect(base.reportsSupport(for: .coolant) == true)
    #expect(base.reportsSupport(for: .rpm) == true)
    #expect(base.reportsSupport(for: .moduleVoltage) == nil)

    let extended = try OBDDecoder.supportMask(.pids41To60, response: "414040000000")
    #expect(extended.reportsSupport(for: .moduleVoltage) == true)
    #expect(extended.reportsSupport(for: .rpm) == nil)
}

@Test func supportMasksRejectWrongPageMalformedPayloadAndConflictingECUs() {
    for malformed in ["", "41000810", "41000810000101", "41000810001Z", "414040000000", "7E8410008100001"] {
        #expect(throws: OBDError.malformedResponse) {
            try OBDDecoder.supportMask(.pids01To20, response: malformed)
        }
    }
    #expect(throws: OBDError.ambiguousResponse) {
        try OBDDecoder.supportMask(.pids01To20, response: "410008100001\r410008000001")
    }
}

@MainActor
@Test func directMeasurementsRemainAuthoritativeAfterNegativeSupportMasks() async throws {
    let transport = CapabilityFixture()
    let client = ELM327Client(transport: transport)
    try await client.initialize()
    let result = try await client.readCoolant()
    #expect(result.value == 83)
    #expect(transport.commands == ELM327Client.initializationCommands + ["0105"])

    let base = try await client.probeSupport(.pids01To20)
    let extensionPage = try await client.probeSupport(.pids41To60)
    #expect(base?.reportsSupport(for: .coolant) == false)
    #expect(base?.reportsSupport(for: .rpm) == false)
    #expect(extensionPage?.reportsSupport(for: .moduleVoltage) == false)

    let snapshot = try await client.readSupplementary(source: .vehicle, coolant: result)
    #expect(snapshot.rpm?.value == 800)
    #expect(snapshot.voltage?.value == 14.2)
    #expect(snapshot.voltageSource == .ecu)
    #expect(transport.commands.suffix(4) == ["0100", "0140", "010C", "0142"])
}

@MainActor
@Test func rejectedProbeIsAdvisoryButTimeoutIsNotSwallowed() async throws {
    let transport = CapabilityFixture()
    let client = ELM327Client(transport: transport)
    for invalid in ["NO DATA", "?", "41000000000Z", "410000000000\r410000000001"] {
        transport.maskReply = .success(invalid)
        let result = try await client.probeSupport(.pids01To20)
        #expect(result == nil)
    }
    transport.maskReply = .failure(.timeout)
    await #expect(throws: OBDError.timeout) { try await client.probeSupport(.pids01To20) }
}

@MainActor
@Test func probePropagatesExplicitAdapterAndBusFaults() async {
    let transport = CapabilityFixture()
    let client = ELM327Client(transport: transport)
    for (reply, fault) in [("LV RESET", "LVRESET"), ("BUFFER FULL", "BUFFERFULL"), ("CAN ERROR", "CANERROR")] {
        transport.maskReply = .success(reply)
        await #expect(throws: OBDError.adapter(fault)) { try await client.probeSupport(.pids01To20) }
    }
}

@MainActor
@Test func probeCannotOverlapWithELMInitialization() async throws {
    let transport = CapabilityFixture(suspendInitialization: true)
    let client = ELM327Client(transport: transport)
    let initialization = Task { try await client.initialize() }
    var iterator = transport.started.makeAsyncIterator()
    _ = await iterator.next()
    await #expect(throws: OBDError.busy) { try await client.probeSupport(.pids01To20) }
    transport.resumeInitialization()
    try await initialization.value
    #expect(!transport.commands.contains("0100"))
}

@MainActor
@Test func capabilitiesOnlyExtendTheReadOnlyCommandAllowlist() {
    #expect(ELM327Client.allowedCommands == [
        "ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0", "0100", "0105", "010C", "0140", "0142", "ATRV"
    ])
}

@MainActor private final class CapabilityFixture: OBDTransport {
    var maskReply: Result<String, OBDError> = .success("410000000000")
    private(set) var commands: [String] = []
    private let signal = AsyncStream<Void>.makeStream()
    private var pause: CheckedContinuation<Void, Never>?
    private let suspendInitialization: Bool

    init(suspendInitialization: Bool = false) {
        self.suspendInitialization = suspendInitialization
    }

    var started: AsyncStream<Void> { signal.stream }
    func connect() async throws {}
    func disconnect() {}

    func resumeInitialization() {
        pause?.resume()
        pause = nil
    }

    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        commands.append(command)
        switch command {
        case "ATZ":
            if suspendInitialization {
                await withCheckedContinuation {
                    pause = $0
                    signal.continuation.yield(())
                }
            }
            return "ELM327 v2.3"
        case "0100": return try maskReply.get()
        case "0140": return "414000000000"
        case "0105": return "41057B"
        case "010C": return "410C0C80"
        case "0142": return "41423778"
        default: return "OK"
        }
    }
}
