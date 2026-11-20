// The iOS 26 SDK leaves Activity's async methods unannotated. This class owns the handles on MainActor.
@preconcurrency import ActivityKit
import CarGaugeCore
import Foundation
import WidgetKit

@MainActor final class TelemetryPresentation {
    private var activity: Activity<CarGaugeAttributes>?
    private var lastActivityUpdate: Date?
    private var lastWidgetWrite: Date?
    private var lastPublishedLevel: ThermalLevel?

    var hasActivity: Bool { activity?.activityState == .active || activity?.activityState == .stale }

    func cleanUpPreviousRun() {
        let previous = Activity<CarGaugeAttributes>.activities
        Task {
            for item in previous { await item.end(nil, dismissalPolicy: .immediate) }
        }
        clearWidget()
    }

    func startActivity(coolant: Reading, source: DataSource, level: ThermalLevel) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PresentationError.activitiesDisabled }
        guard coolant.isFresh(at: Date()) else { throw PresentationError.noFreshData }
        guard !hasActivity else { return }
        activity = try Activity.request(
            attributes: CarGaugeAttributes(source: source),
            content: content(for: coolant, level: level),
            pushType: nil
        )
        lastActivityUpdate = coolant.timestamp
    }

    func endActivity() {
        guard let old = activity else { return }
        activity = nil
        lastActivityUpdate = nil
        Task { await old.end(nil, dismissalPolicy: .immediate) }
    }

    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) async {
        let changedLevel = lastPublishedLevel != level
        lastPublishedLevel = level

        if changedLevel || (lastWidgetWrite.map { coolant.timestamp.timeIntervalSince($0) >= 60 } ?? true) {
            let snapshot = WidgetSnapshot(source: source, temperature: Int(coolant.value),
                                          sampleDate: coolant.timestamp, level: level)
            if WidgetSnapshotStore.write(snapshot) {
                lastWidgetWrite = coolant.timestamp
                WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot")
            }
        }

        if hasActivity, let activity,
           changedLevel || (lastActivityUpdate.map { coolant.timestamp.timeIntervalSince($0) >= 8 } ?? true) {
            lastActivityUpdate = coolant.timestamp
            await activity.update(content(for: coolant, level: level))
        }
    }

    func markActivityStale() async {
        guard hasActivity, let activity else { return }
        lastActivityUpdate = nil
        await activity.update(ActivityContent(state: activity.content.state, staleDate: .now))
    }

    func clearWidget() {
        lastWidgetWrite = nil
        lastPublishedLevel = nil
        WidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot")
    }

    private func content(for reading: Reading, level: ThermalLevel) -> ActivityContent<CarGaugeAttributes.ContentState> {
        let state = CarGaugeAttributes.ContentState(coolant: Int(reading.value), sampleDate: reading.timestamp, level: level)
        return ActivityContent(state: state, staleDate: reading.timestamp.addingTimeInterval(20), relevanceScore: 0)
    }

    private enum PresentationError: LocalizedError {
        case activitiesDisabled, noFreshData
        var errorDescription: String? {
            switch self {
            case .activitiesDisabled: "Разрешите Live Activities для CarGauge в настройках iPhone."
            case .noFreshData: "Дождитесь свежего показания температуры."
            }
        }
    }
}
