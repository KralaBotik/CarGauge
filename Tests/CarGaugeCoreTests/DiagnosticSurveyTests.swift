import CarGaugeCore
import Foundation
import Testing

@MainActor private final class SurveyFixture: OBDTransport {
    var sent: [String] = []
    var replies: [String: String]
    var failing: String?

    init(_ replies: [String: String]) { self.replies = replies }
    func connect() async throws {}
    func disconnect() {}
    func exchange(_ command: String, timeout: TimeInterval) async throws -> String {
        sent.append(command)
        if command == failing { throw OBDError.timeout }
        return replies[command] ?? "NO DATA"
    }
}

@MainActor @Test func surveyOnlyFollowsAdvertisedReadPagesAndExportsEvidence() async throws {
    let fixture = SurveyFixture([
        "ATDPN":"A6", "0100":"410008100003", "0120":"412000000001", "0140":"414000010004",
        "0101":"410181076104", "03":"43010133", "07":"4700", "0A":"7F0A11",
        "020200":"4202000133", "020000":"42000008000000", "020500":"4205007C",
        "0105":"410584", "010C":"410C0D48", "011F":"411F012C", "0150":"415014000000",
        "015E":"415E0014"
    ])
    let client = ELM327Client(transport: fixture)
    let work = DiagnosticSurvey(firstObservedCoolantAt: Date(timeIntervalSince1970: 1), adapterName: "Fixture")
    for _ in 0..<40 { try await work.performNext(with: client) }
    let report = work.report
    #expect(report.state == .completed)
    #expect(fixture.sent == ["ATDPN","0100","0120","0140","0101","03","07","0A","020200","020000",
                             "0105","010C","011F","0150","015E","020500"])
    #expect(report.codes.first(where: { $0.status == .stored })?.replyGroups == [["P0133"]])
    #expect(report.codes.first(where: { $0.status == .pending })?.replyGroups == [[]])
    #expect(report.codes.first(where: { $0.status == .permanent }) == nil)
    #expect(report.exchanges.first(where: { $0.command == "0A" })?.outcome == .negative)
    #expect(report.readiness.first?.milOn == true)
    #expect(report.readiness.first?.monitors.contains(where: { !$0.supported && $0.complete == nil }) == true)
    #expect(report.freezeCauses == ["P0133"])
    #expect(report.measurements.first(where: { $0.freezeFrame == 0 })?.value == 84)
    #expect(report.measurements.first(where: { $0.sensor == .engineRunTime })?.value == 300)
    #expect(report.measurements.first(where: { $0.sensor == .fuelRate })?.value == 1)
    #expect(report.measurements.first(where: { $0.sensor == .maximumAirFlow })?.value == nil)
    #expect(report.measurements.first(where: { $0.sensor == .maximumAirFlow })?.rawBytes == [20, 0, 0, 0])
    #expect(report.modules.first(where: { $0.id == "abs" })?.status == .profileUnverified)
    let masked = try #require(String(data: report.json(includeRaw: false), encoding: .utf8))
    let full = try #require(String(data: report.json(includeRaw: true), encoding: .utf8))
    #expect(!masked.contains("rawResponse\""))
    #expect(full.contains("rawResponse"))
    #expect(masked.contains("not_collected"))
    #expect(report.csv().contains("ecu_freeze_frame"))
}

@MainActor @Test func surveyDoesNotGuessTransportOrFreezeAvailability() async throws {
    let fixture = SurveyFixture(["ATDPN":"AB", "0100":"410008000000", "020200":"NO DATA"])
    let client = ELM327Client(transport: fixture)
    let work = DiagnosticSurvey(firstObservedCoolantAt: nil, adapterName: nil)
    for _ in 0..<20 { try await work.performNext(with: client) }
    #expect(work.report.state == .completed)
    #expect(fixture.sent == ["ATDPN","0100","0101","020200","0105"])
    #expect(work.report.codes.isEmpty)
    #expect(work.report.freezeCauses.isEmpty)
    #expect(work.report.exchanges.first(where: { $0.command == "020200" })?.outcome == .noData)
}

@MainActor @Test func timedOutSurveyStopsAndReturnsLinkFailureToTelemetryOwner() async throws {
    let fixture = SurveyFixture(["ATDPN":"6"])
    fixture.failing = "0100"
    let client = ELM327Client(transport: fixture)
    let work = DiagnosticSurvey(firstObservedCoolantAt: nil, adapterName: nil)
    try await work.performNext(with: client)
    do {
        try await work.performNext(with: client)
        Issue.record("Expected a timeout")
    } catch let error as OBDError {
        #expect(error == .timeout)
    }
    try await work.performNext(with: client)
    #expect(work.report.state == .interrupted)
    #expect(work.report.exchanges.last?.outcome == .timeout)
    #expect(fixture.sent == ["ATDPN","0100"])
}

@MainActor @Test func surveyWhitelistRejectsWritesHeadersAndArbitraryCommands() {
    for command in ["04","08","10C0","1101","14000000","220001","2E000100","3101","2701","ATSH7E0",
                    "ATMA","01FF","0105010C","0105\r04","020501","ATRV\n04"] {
        #expect(!ELM327Client.allowedCommands.contains(command))
    }
    for command in ["ATDPN","0100","01E0","0101","03","07","0A","020200","020000","015E"] {
        #expect(ELM327Client.allowedCommands.contains(command))
    }
}

@MainActor @Test func automaticDiagnosticRecordsOnlyDTCsAndDoesNotTurnSilenceIntoAnEmptyResult() async throws {
    let fixture = SurveyFixture(["ATDPN": "A6", "03": "4300", "07": "4700", "0A": "NO DATA"])
    let work = DiagnosticSurvey(firstObservedCoolantAt: nil, adapterName: "CI", source: .simulator, scope: .codesOnly)
    let client = ELM327Client(transport: fixture)
    for _ in 0..<6 { try await work.performNext(with: client) }
    #expect(fixture.sent == ["ATDPN", "03", "07", "0A"])
    #expect(work.report.state == .completed)
    #expect(work.report.source == "test_fixture")
    #expect(work.report.codes.first { $0.status == .stored }?.replyGroups == [[]])
    #expect(work.report.codes.first { $0.status == .pending }?.replyGroups == [[]])
    #expect(work.report.codes.first { $0.status == .permanent } == nil)
    #expect(work.report.exchanges.last?.outcome == .noData)
}
