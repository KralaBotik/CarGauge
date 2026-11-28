import Foundation

public struct MaintenanceFuelInterval: Identifiable, Sendable {
    public var id: UUID { end.id }
    public let start: MaintenanceFill
    public let end: MaintenanceFill
    public let litres: Double
    public let distanceKm: Double
    public var litresPer100km: Double { 100 * litres / distanceKm }
}

public struct MaintenanceExpenses: Sendable {
    public let fuelMinor: Int64?
    public let maintenanceMinor: Int64?
    public let repairMinor: Int64?
    public let totalMinor: Int64?
    public let knownCostPerKmMinor: Double?
    public let entriesWithUnknownCost: Int
}

extension MaintenanceLedger {
    /// Once a tank is full, litres added at every known fill through the next
    /// full tank reconstruct aggregate consumption. Neither endpoint alone
    /// licenses an estimate for an interval with an unknown date or odometer.
    public var fuelIntervals: [MaintenanceFuelInterval] {
        guard fills.allSatisfy({ $0.date.value != nil }) else { return [] }
        let ordered = fills.sorted { ($0.date.value ?? .distantPast) < ($1.date.value ?? .distantPast) }
        let duplicateDates = Set(Dictionary(grouping: ordered, by: \.date.value).filter { $0.value.count > 1 }.keys)
        var start: MaintenanceFill?
        var previous: MaintenanceFill?
        var volume = 0.0
        var complete = false
        var result: [MaintenanceFuelInterval] = []
        for entry in ordered {
            let reliable = entry.date.certainty == .exact && entry.odometer.certainty == .exact
                && (entry.odometer.value?.isFinite == true) && (entry.odometer.value ?? -1) >= 0
                && entry.litres.isFinite && entry.litres > 0
            if let previous {
                complete = complete && reliable && (entry.date.value ?? .distantPast) > (previous.date.value ?? .distantPast)
                    && (entry.odometer.value ?? -1) >= (previous.odometer.value ?? .infinity)
            }
            if start != nil { volume += entry.litres }
            if entry.fullTank {
                if complete, let start, let left = start.odometer.value, let right = entry.odometer.value,
                   volume.isFinite && right > left,
                   !duplicateDates.contains(entry.date.value) {
                    result.append(.init(start: start, end: entry, litres: volume, distanceKm: right - left))
                }
                start = reliable ? entry : nil
                complete = reliable && !duplicateDates.contains(entry.date.value)
                volume = 0
            }
            previous = entry
        }
        return result.reversed()
    }

    public var expenses: MaintenanceExpenses {
        let jobs = records.flatMap(\.work)
        let fuel = Self.sum(fills.compactMap(\.knownCost))
        let maintenance = Self.sum(jobs.filter { $0.operation != .repair }.compactMap(\.knownCost))
        let repairs = Self.sum(jobs.filter { $0.operation == .repair }.compactMap(\.knownCost))
        let total = Self.sum([fuel, maintenance, repairs].compactMap { $0 })
        let unknown = jobs.filter { !$0.allCostsKnown }.count + fills.filter { $0.knownCost == nil }.count
        return .init(fuelMinor: fuel, maintenanceMinor: maintenance, repairMinor: repairs, totalMinor: total,
                     knownCostPerKmMinor: knownCostPerKm, entriesWithUnknownCost: unknown)
    }

    private var knownCostPerKm: Double? {
        let precise = odometers.filter { $0.odometer.certainty == .exact }.sorted { $0.date < $1.date }
        guard let first = precise.first, let last = precise.last, first.id != last.id,
              !precise.dropFirst().contains(where: \.correction),
              let startKm = first.odometer.value, let endKm = last.odometer.value, endKm > startKm,
              records.allSatisfy({ $0.date.certainty == .exact }),
              fills.allSatisfy({ $0.date.certainty == .exact }) else { return nil }
        let start = first.date
        let end = last.date
        let jobs = records.filter { $0.date.value.map { $0 > start && $0 <= end } == true }.flatMap(\.work)
        let fuel = fills.filter { $0.date.value.map { $0 > start && $0 <= end } == true }
        guard jobs.allSatisfy(\.allCostsKnown), fuel.allSatisfy({ $0.knownCost != nil }),
              let spend = Self.sum(jobs.compactMap(\.knownCost) + fuel.compactMap(\.knownCost)) else { return nil }
        return Double(spend) / (endKm - startKm)
    }

    private static func sum(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        var total: Int64 = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            if result.overflow { return nil }
            total = result.partialValue
        }
        return total
    }
}
