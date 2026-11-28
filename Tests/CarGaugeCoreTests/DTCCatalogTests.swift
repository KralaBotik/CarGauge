import CarGaugeCore
import Foundation
import Testing

@Test func dtcCatalogueNormalizesKnownCodesWithoutGuessingUnknownDefinitions() throws {
    let code = try #require(DTCCatalog.lookup(" p0128\n"))
    #expect(code.code == "P0128")
    #expect(code.title.contains("температуры"))
    #expect(code.urgency == .contextDependent)
    for value in ["P0173", "U0128", "P01280", "P0 128", "430128", "Р0128", ""] {
        #expect(DTCCatalog.lookup(value) == nil)
    }
}

@Test func dtcCataloguePreservesElectricalAndMisfireDistinctionsInReports() throws {
    let lowInput = try #require(DTCCatalog.lookup("P0117"))
    let highInput = try #require(DTCCatalog.lookup("P0118"))
    let misfire = try #require(DTCCatalog.lookup("P0304"))
    #expect(lowInput.title.hasPrefix("Низкий сигнал"))
    #expect(highInput.title.hasPrefix("Высокий сигнал"))
    #expect(lowInput.limits.contains("электрическому сигналу"))
    #expect(misfire.title.hasSuffix("4"))
    #expect(misfire.urgency == .promptInspection)
    #expect(try JSONDecoder().decode(DTCDescription.self, from: JSONEncoder().encode(misfire)) == misfire)
}
