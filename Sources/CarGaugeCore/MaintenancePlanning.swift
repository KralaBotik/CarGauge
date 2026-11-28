import Foundation

public struct MaintenanceCounters: Sendable {
    public var odometerKm: Double?
    public var engineHours: Double?
    public var odometerCertainty: MaintenanceCertainty
    public var engineHoursCertainty: MaintenanceCertainty
    public var estimatedOdometerKm: Double?
    public var observedEngineHours: Double?

    public init(odometerKm: Double? = nil, engineHours: Double? = nil,
                odometerCertainty: MaintenanceCertainty = .exact, engineHoursCertainty: MaintenanceCertainty = .exact,
                estimatedOdometerKm: Double? = nil, observedEngineHours: Double? = nil) {
        self.odometerKm = odometerKm
        self.engineHours = engineHours
        self.odometerCertainty = odometerKm == nil ? .unknown : odometerCertainty
        self.engineHoursCertainty = engineHours == nil ? .unknown : engineHoursCertainty
        self.estimatedOdometerKm = estimatedOdometerKm
        self.observedEngineHours = observedEngineHours
    }
}

extension MaintenanceLedger {
    /// The reported odometer remains the owner's value. The separate estimate
    /// accumulates only observed distance since its timestamp.
    public func odometerCounters(observed: MaintenanceUsage = .init()) -> MaintenanceCounters {
        let latest = latestOdometer
        let odometer = latest?.odometer.value
        let estimate = odometer.flatMap { baseline in
            observed.distanceKm.flatMap { distance in
                distance.isFinite && distance > 0 && (baseline + distance).isFinite ? baseline + distance : nil
            }
        }
        return MaintenanceCounters(odometerKm: odometer, engineHours: latest?.engineHours.value,
                                   odometerCertainty: latest?.odometer.certainty ?? .unknown,
                                   engineHoursCertainty: latest?.engineHours.certainty ?? .unknown,
                                   estimatedOdometerKm: estimate,
                                   observedEngineHours: observed.engineHours.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
}

public enum MaintenanceDueState: String, Codable, Sendable, CaseIterable, Identifiable {
    case unknownHistory, notNeeded, soon, due, overdue, requiresInspection, replacementRecommended
    public var id: Self { self }
    public var title: String {
        switch self {
        case .unknownHistory: "История или интервал неизвестны"
        case .notNeeded: "Срок пока не наступил"
        case .soon: "Скоро потребуется"
        case .due: "Срок наступил"
        case .overdue: "Просрочено"
        case .requiresInspection: "Требуется осмотр"
        case .replacementRecommended: "Осмотром рекомендована замена"
        }
    }

    public var rank: Int {
        switch self {
        case .replacementRecommended: 6
        case .overdue: 5
        case .due: 4
        case .requiresInspection: 3
        case .soon: 2
        case .unknownHistory: 1
        case .notNeeded: 0
        }
    }

    public var canRemind: Bool { rank >= 2 }
}

public struct MaintenanceDue: Identifiable, Sendable {
    public var id: String {
        rule?.id.uuidString ?? component.id + (recordID == nil ? "-catalog" : "-inspection-" + (position?.rawValue ?? "unspecified"))
    }
    public let component: MaintenanceComponent
    public let state: MaintenanceDueState
    public let dueDate: Date?
    public let dueKm: Double?
    public let dueHours: Double?
    public let approximate: Bool
    public let rule: MaintenanceRule?
    public let recordID: UUID?
    public var position: MaintenancePosition? = nil
}

public enum MaintenanceDueEvaluator {
    public static func statuses(ledger: MaintenanceLedger, current: MaintenanceCounters, now: Date = .now,
                                calendar: Calendar = .current) -> [MaintenanceDue] {
        var result: [MaintenanceDue] = []
        let rules = ledger.rules.filter { $0.regime == nil || $0.regime == ledger.settings.regime }
        for component in ledger.components {
            let rulesForComponent = rules.filter { $0.componentID == component.id }
            let tracked = ledger.records.filter { record in
                (record.date.value.map { $0 <= now } ?? true) && record.work.contains { $0.componentID == component.id }
            }
            for rule in rulesForComponent {
                let anchor = latest(tracked.filter { record in
                    record.work.contains { $0.componentID == component.id && $0.operation == rule.operation }
                })
                result.append(schedule(rule: rule, component: component, anchor: anchor, current: current,
                                       settings: ledger.settings, now: now, calendar: calendar))
            }
            let findings = observedConditions(component: component, records: tracked, settings: ledger.settings,
                                              now: now, calendar: calendar)
            result += findings
            if findings.isEmpty && rulesForComponent.isEmpty {
                result.append(.init(component: component, state: .unknownHistory, dueDate: nil, dueKm: nil,
                                    dueHours: nil, approximate: false, rule: nil, recordID: nil))
            }
        }
        return result.sorted {
            $0.state.rank == $1.state.rank ? $0.component.title < $1.component.title : $0.state.rank > $1.state.rank
        }
    }

    private static func latest(_ records: [MaintenanceRecord]) -> MaintenanceRecord? {
        records.max { a, b in
            if a.displayDate != b.displayDate { return a.displayDate < b.displayDate }
            if a.enteredAt != b.enteredAt { return a.enteredAt < b.enteredAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    private static func schedule(rule: MaintenanceRule, component: MaintenanceComponent, anchor: MaintenanceRecord?,
                                 current: MaintenanceCounters, settings: MaintenanceSettings, now: Date,
                                 calendar: Calendar) -> MaintenanceDue {
        let start = calendar.startOfDay(for: now)
        let dueDate = rule.months.flatMap { months in
            anchor?.date.value.flatMap { calendar.date(byAdding: .month, value: months, to: calendar.startOfDay(for: $0)) }
        }
        let dueKm = rule.distanceKm.flatMap { distance in anchor?.odometer.value.map { $0 + distance } }
        let dueHours = rule.engineHours.flatMap { hours in anchor?.engineHours.value.map { $0 + hours } }
        let calendarStatus = dueDate.map {
            let remaining = calendar.dateComponents([.day], from: start, to: $0).day
            return severity(remaining.map(Double.init), lead: Double(settings.leadDays), exact: anchor?.date.certainty == .exact)
        }
        let mileageStatus = dueKm.map { limit in
            let remainder = current.odometerKm.flatMap { value in
                value >= (anchor?.odometer.value ?? .infinity) ? limit - value : nil
            }
            return severity(remainder, lead: settings.leadKm,
                            exact: current.odometerCertainty == .exact && anchor?.odometer.certainty == .exact)
        }
        let hoursStatus = dueHours.map { limit in
            severity(current.engineHours.flatMap { value in value >= (anchor?.engineHours.value ?? .infinity) ? limit - value : nil },
                     lead: settings.leadHours, exact: current.engineHoursCertainty == .exact && anchor?.engineHours.certainty == .exact)
        }
        let axes = [(rule.months != nil, calendarStatus), (rule.distanceKm != nil, mileageStatus),
                    (rule.engineHours != nil, hoursStatus)].filter { $0.0 }.map { $0.1 ?? .unknownHistory }
        let state = axes.max { $0.rank < $1.rank } ?? .unknownHistory
        let approximate = (dueDate != nil && anchor?.date.certainty == .approximate)
            || (dueKm != nil && (anchor?.odometer.certainty == .approximate || current.odometerCertainty == .approximate))
            || (dueHours != nil && (anchor?.engineHours.certainty == .approximate || current.engineHoursCertainty == .approximate))
        return .init(component: component, state: state, dueDate: dueDate, dueKm: dueKm, dueHours: dueHours,
                     approximate: approximate, rule: rule, recordID: anchor?.id)
    }

    private static func severity(_ remainder: Double?, lead: Double, exact: Bool) -> MaintenanceDueState {
        guard exact, let remainder, remainder.isFinite else { return .unknownHistory }
        if remainder < 0 { return .overdue }
        if remainder == 0 { return .due }
        if remainder <= lead { return .soon }
        return .notNeeded
    }

    private static func observedConditions(component: MaintenanceComponent, records: [MaintenanceRecord],
                                           settings: MaintenanceSettings, now: Date, calendar: Calendar) -> [MaintenanceDue] {
        let included = records.flatMap(\.work).filter {
            $0.componentID == component.id && ($0.inspection?.finding == .replacement
                || $0.inspection?.finding == .recheck || $0.inspection?.nextCheck != nil)
        }
        let positions = Set(included.compactMap { $0.inspection?.position })
        return MaintenancePosition.allCases.filter(positions.contains).compactMap { position in
            let changes = records.filter { record in
                record.work.contains { affectsCondition($0, componentID: component.id, position: position) }
            }
            guard let record = latest(changes),
                  let work = record.work.last(where: { affectsCondition($0, componentID: component.id, position: position) }),
                  let inspection = work.inspection, inspection.position == position,
                  inspection.finding == .replacement || inspection.finding == .recheck || inspection.nextCheck != nil
            else { return nil }
            let state: MaintenanceDueState
            if inspection.finding == .replacement {
                state = .replacementRecommended
            } else if let date = inspection.nextCheck {
                let remaining = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                        to: calendar.startOfDay(for: date)).day ?? 0
                state = remaining <= 0 ? .requiresInspection : (remaining <= settings.leadDays ? .soon : .notNeeded)
            } else {
                state = .requiresInspection
            }
            return .init(component: component, state: state, dueDate: inspection.nextCheck, dueKm: nil, dueHours: nil,
                         approximate: false, rule: nil, recordID: record.id, position: position)
        }
    }

    private static func affectsCondition(_ work: MaintenanceWork, componentID: String, position: MaintenancePosition) -> Bool {
        guard work.componentID == componentID else { return false }
        let placement = work.inspection?.position ?? .unspecified
        let clears = work.operation == .replacement || work.inspection?.finding == .satisfactory
        if placement == position {
            return clears || work.inspection?.nextCheck != nil || (work.inspection.map { $0.finding != .unknown } ?? false)
        }
        guard clears else { return false }
        if work.operation == .replacement && placement == .unspecified { return true }
        if placement == .front { return position == .frontLeft || position == .frontRight }
        if placement == .rear { return position == .rearLeft || position == .rearRight }
        return false
    }
}
