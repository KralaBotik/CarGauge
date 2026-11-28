import Foundation
import Testing
@testable import CarGaugeCore

private let utc = Calendar(identifier: .gregorian).withUTC
private extension Calendar {
    var withUTC: Self {
        var calendar = self
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utc.date(from: .init(year: year, month: month, day: day))!
}
private func work(_ action: MaintenanceOperation, _ component: String = "engine-oil") -> MaintenanceWork {
    MaintenanceWork(componentID: component, operation: action)
}
private func issue(_ ledger: MaintenanceLedger, current: MaintenanceCounters = .init(), now: Date = day(2026, 11, 28)) -> MaintenanceDue? {
    MaintenanceDueEvaluator.statuses(ledger: ledger, current: current, now: now, calendar: utc).first { $0.component.id == "engine-oil" }
}

@Test func maintenanceReplacementSurvivesInspectionAndTopUp() throws {
    var ledger = MaintenanceLedger()
    try ledger.apply(.saveRule(.init(componentID: "engine-oil", operation: .replacement, months: 12, distanceKm: 10_000)))
    #expect(issue(ledger)?.state == .unknownHistory)
    let replacement = MaintenanceRecord(date: .init(day(2025, 11, 28)), odometer: .init(120_000), work: [work(.replacement)])
    try ledger.apply(.saveRecord(replacement))
    try ledger.apply(.saveRecord(.init(date: .init(day(2026, 9, 10)), odometer: .init(125_000),
                                        work: [work(.inspection), work(.topUp)])))
    let due = try #require(issue(ledger, current: .init(odometerKm: 129_000)))
    #expect(due.recordID == replacement.id)
    #expect(due.dueDate == day(2026, 11, 28))
    #expect(due.dueKm == 130_000)
    #expect(due.state == .due)
    #expect(issue(ledger, current: .init(odometerKm: 130_001), now: day(2026, 5, 1))?.state == .overdue)
    let next = MaintenanceRecord(date: .init(day(2026, 11, 27)), odometer: .init(129_000), work: [work(.replacement)])
    try ledger.apply(.saveRecord(next))
    #expect(issue(ledger, current: .init(odometerKm: 129_000))?.recordID == next.id)
    #expect(issue(ledger, current: .init(odometerKm: 129_000))?.state == .notNeeded)
}

@Test func maintenanceApproximateDatesAndUnknownAxesDoNotAuthorizeAnAlert() throws {
    var ledger = MaintenanceLedger()
    try ledger.apply(.saveRule(.init(componentID: "engine-oil", operation: .replacement, months: 12, engineHours: 100)))
    try ledger.apply(.saveRecord(.init(date: .init(day(2024, 1, 10), certainty: .approximate),
                                        work: [work(.replacement)])))
    let due = try #require(issue(ledger, current: .init(engineHours: 350)))
    #expect(due.state == .unknownHistory)
    #expect(due.approximate)
    #expect(due.dueDate == day(2025, 1, 10))
    #expect(!due.state.canRemind)
}

@Test func maintenanceSevereProfileAndFindingsAreExplicit() throws {
    var ledger = MaintenanceLedger()
    try ledger.apply(.saveRule(.init(componentID: "engine-oil", operation: .replacement, regime: .normal, months: 12)))
    try ledger.apply(.saveRule(.init(componentID: "engine-oil", operation: .replacement, regime: .severe, months: 6)))
    try ledger.apply(.saveRecord(.init(date: .init(day(2026, 1, 1)), work: [work(.replacement)])))
    #expect(issue(ledger)?.state == .notNeeded)
    try ledger.apply(.settings(.init(regime: .severe)))
    #expect(issue(ledger)?.state == .overdue)
    let previous = MaintenanceWork(componentID: "front-pads", operation: .inspection,
        inspection: .init(position: .front, finding: .replacement, measurements: [.init(kind: .frictionMm, value: 2.4)]))
    try ledger.apply(.saveRecord(.init(date: .init(day(2026, 7, 1)), work: [previous])))
    let observed = MaintenanceDueEvaluator.statuses(ledger: ledger, current: .init(), now: day(2026, 8, 1), calendar: utc)
    #expect(observed.first { $0.component.id == "front-pads" }?.state == .replacementRecommended)
    try ledger.apply(.saveRecord(.init(date: .init(day(2026, 8, 2)), work: [previous, work(.replacement, "front-pads")])))
    let fixed = MaintenanceDueEvaluator.statuses(ledger: ledger, current: .init(), now: day(2026, 8, 3), calendar: utc)
    #expect(fixed.first { $0.component.id == "front-pads" }?.state == .unknownHistory)
}

@Test func maintenanceOdometerCorrectionPreservesManualEvidence() throws {
    var ledger = MaintenanceLedger()
    try ledger.apply(.saveOdometer(.init(date: day(2026, 1, 1), odometer: .init(110_000))))
    let correction = MaintenanceOdometer(date: day(2026, 2, 1), odometer: .init(109_980), correction: true)
    #expect(throws: MaintenanceValidationError.invalidOdometerOrder) {
        try ledger.apply(.saveOdometer(.init(date: correction.date, odometer: correction.odometer)))
    }
    try ledger.apply(.saveOdometer(correction))
    let counters = ledger.odometerCounters(observed: .init(distanceKm: 41.5, engineHours: 2.2))
    #expect(counters.odometerKm == 109_980)
    #expect(counters.estimatedOdometerKm == 110_021.5)
    #expect(counters.engineHours == nil)
    #expect(counters.observedEngineHours == 2.2)
    #expect(ledger.odometers.count == 2)
}

@Test func maintenanceFullTankIncludesRecordedPartialFillsButRejectsUnknownInterval() throws {
    var ledger = MaintenanceLedger()
    for (date, odometer, litres, full) in [
        (day(2026, 11, 1), 120_000.0, 30.0, true),
        (day(2026, 11, 2), 120_200, 10, false),
        (day(2026, 11, 10), 120_400, 18, true)
    ] {
        try ledger.apply(.saveFill(.init(date: .init(date), odometer: .init(odometer), litres: litres, fullTank: full)))
    }
    let interval = try #require(ledger.fuelIntervals.first)
    #expect(interval.litres == 28)
    #expect(interval.distanceKm == 400)
    #expect(interval.litresPer100km == 7)
    try ledger.apply(.saveFill(.init(date: .init(), odometer: .init(), litres: 8, fullTank: false)))
    #expect(ledger.fuelIntervals.isEmpty)
}

@Test func maintenanceBundleValidationRedactionAndDeleteAreSeparate() throws {
    var ledger = MaintenanceLedger()
    let part = MaintenancePart(maker: "Тестовая марка", partNumber: "Частные данные", costMinor: 9_000)
    let brake = MaintenanceWork(componentID: "front-discs", operation: .inspection, parts: [part], laborCostMinor: 0,
        inspection: .init(position: .frontLeft, finding: .recheck, measurements: [
            .init(kind: .discMm, value: 24),
            .init(kind: .discLimitMm, value: 22, source: "Маркировка на детали")
        ]))
    let attachment = MaintenanceAttachment(filename: "phone-private.pdf", mediaType: "application/pdf", data: Data([1, 2, 3]))
    var record = MaintenanceRecord(date: .init(), provider: .selfService, comment: "Личные сведения", work: [brake, work(.topUp)],
                                   attachments: [attachment])
    try ledger.apply(.saveRecord(record))
    #expect(ledger.records.count == 1)
    #expect(ledger.records.first?.work.count == 2)
    #expect(ledger.attachmentBytes == 3)
    let redacted = ledger.redactedCopy()
    #expect(redacted.records.first?.attachments.isEmpty == true)
    #expect(redacted.records.first?.work.first?.parts.first?.partNumber == "")
    #expect(redacted.records.first?.work.first?.inspection?.measurements.count == 2)
    #expect(ledger.expenses.totalMinor == 9_000)
    record.attachments[0].data = Data(repeating: 0, count: MaintenanceLedger.fileByteLimit + 1)
    #expect(throws: MaintenanceValidationError.fileLimit) { try ledger.apply(.saveRecord(record)) }
    #expect(ledger.attachmentBytes == 3)
    try ledger.apply(.deleteRecord(record.id))
    #expect(ledger.records.isEmpty)
}
