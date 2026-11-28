@testable import CarGaugeCore
import Foundation
import Testing

private func survey(at second: Double, stored: [[String]]? = nil,
                    pending: [[String]]? = nil, isComplete: Bool = true) -> DiagnosticReport {
    let date = Date(timeIntervalSince1970: second)
    var report = DiagnosticReport(startedAt: date, firstObservedCoolantAt: nil,
                                  adapterName: "пользовательское имя", adapterIdentification: "ELM327",
                                  source: .vehicle, stationaryConfirmedByUser: false)
    report.transportProtocol = .can11Bit500
    report.state = isComplete ? .completed : .interrupted
    report.finishedAt = date.addingTimeInterval(1)
    if let stored { report.codes.append(.init(status: .stored, replyGroups: stored)) }
    if let pending { report.codes.append(.init(status: .pending, replyGroups: pending)) }
    return report
}

@Test func diagnosticJournalDeduplicatesAndDoesNotClearOnSilenceOrAmbiguousCoverage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = TelemetryArchive(url: root.appending(path: "history.sqlite"))
    let first = survey(at: 10, stored: [["P0133"]], pending: [["P0133"]])
    try await archive.saveDiagnostic(first)
    try await archive.saveDiagnostic(first)
    try await archive.saveDiagnostic(survey(at: 20))
    try await archive.saveDiagnostic(survey(at: 30, stored: [[], []]))
    try await archive.saveDiagnostic(survey(at: 40, pending: [[]], isComplete: false))
    #expect(try await archive.dtcFindings().count == 2)
    #expect(try await archive.dtcFindings().allSatisfy { $0.notReportedAt == nil })
    #expect(try await archive.dtcHistory().count == 2)
    try await archive.saveDiagnostic(survey(at: 50, stored: [[]]))
    #expect(try await archive.dtcFindings().first { $0.status == .stored }?.notReportedAt == nil)
    try await archive.saveDiagnostic(survey(at: 60, stored: [[]]))
    #expect(try await archive.dtcFindings().first { $0.status == .stored }?.notReportedAt?.timeIntervalSince1970 == 60)
    try await archive.saveDiagnostic(survey(at: 55, stored: [["P0133"]]))
    #expect(try await archive.dtcFindings().first { $0.status == .stored }?.appearances == 1)
    try await archive.saveDiagnostic(survey(at: 70, stored: [["P0133"]]))
    let findings = try await archive.dtcFindings()
    #expect(findings.first { $0.status == .stored }?.appearances == 2)
    #expect(findings.first { $0.status == .pending }?.appearances == 1)
}

@Test func migrationFromActualV1SchemaPreservesTripsReadingsAndCalibrationAndBacksUpWAL() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appending(path: "history.sqlite")
    let historical = survey(at: 103, stored: [["P0133"]])
    do {
        let db = try DriveSQL(url: url)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute(TelemetryArchive.schemaV1)
        try db.execute("""
            INSERT INTO trip(id,owner,started_utc,last_utc,finish) VALUES(7,'old',100,105,'engine_stopped');
            INSERT INTO frame(id,trip_id,utc,elapsed,observed,km,base_litres,litres,idle,discontinuous)
              VALUES(77,7,104,4,4,.04,.001,.002,0,0);
            INSERT INTO reading(frame_id,signal,utc,offset,value,quality,bytes)
              VALUES(77,5,103.75,-.25,90,'received','82');
            INSERT INTO fill(id,start_utc,end_utc,km,litres,base_litres,engine_seconds,fuel_seconds,paired_km)
              VALUES(1,20,99,300,24,20,500,500,298);
            """)
        let json = try historical.json(includeRaw: true)
        try db.run("INSERT INTO event(trip_id,utc,kind,payload) VALUES(7,103,'manual_survey',?)",
                   [.text(String(decoding: json, as: UTF8.self))])
    }
    let archive = TelemetryArchive(url: url)
    let old = try #require(await archive.trip(id: 7))
    #expect(old.distanceKm == 0.04)
    #expect(old.litres == 0.002)
    #expect(try await archive.calibration().factor == 1.2)
    #expect(try await archive.plot(tripID: 7, channels: [.coolant]).series[.coolant]?.first?.time == 3.75)
    #expect(try await archive.recordedSurvey(historical.id.uuidString)?.codes.first?.replyGroups == [["P0133"]])
    #expect(try await archive.reserveNotice("notice-1", at: .now))
    #expect(!(try await archive.reserveNotice("notice-1", at: .now)))
    let backup = root.appending(path: "backup.sqlite")
    try await archive.makeBackup(at: backup)
    let copy = try DriveSQL(url: backup)
    #expect(try copy.scalar("PRAGMA user_version") == 2)
    #expect(try copy.scalar("SELECT COUNT(*) FROM reading WHERE bytes='82'") == 1)
    #expect(try copy.scalar("SELECT SUM(litres) FROM fill") == 24)
    #expect(try copy.scalar("SELECT COUNT(*) FROM local_notice") == 1)
    var integrity: String?
    try copy.query("PRAGMA quick_check") { integrity = DriveSQL.string($0, 0) }
    #expect(integrity == "ok")
}
