// The iOS 26 SDK leaves Activity's async methods unannotated. This class owns the handles on MainActor.
@preconcurrency import ActivityKit
import CarGaugeCore
import Foundation
import WidgetKit

@MainActor final class TelemetryPresentation {
    private var activity: Activity<CarGaugeAttributes>?
    private var lifecycle: Task<Void, Never>?
    private var generation = 0
    private var startPending = false
    private var lastActivityUpdate: Date?
    private var lastWidgetWrite: Date?
    private var lastPublishedLevel: ThermalLevel?
    private var lastPublishedSource: DataSource?
    var isForeground = false
    var groupIsAvailable: Bool { WidgetSnapshotStore.containerIsAvailable }

    var hasActivity: Bool {
        startPending || activity?.activityState == .active || activity?.activityState == .stale
    }

    func cleanUpPreviousRun() {
        generation += 1
        startPending = false
        activity = nil
        lastActivityUpdate = nil
        let previous = Activity<CarGaugeAttributes>.activities
        enqueue {
            for item in previous { await item.end(nil, dismissalPolicy: .immediate) }
        }
        clearWidget()
    }

    func startActivity(coolant: Reading, source: DataSource, level: ThermalLevel,
                       onDeferredResult: @escaping @MainActor (Error?) -> Void) throws {
        guard isForeground else { throw PresentationError.needsForeground }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PresentationError.activitiesDisabled }
        guard coolant.isFresh(at: Date()) else { throw PresentationError.noFreshData }
        guard !hasActivity else { return }

        let session = generation
        if lifecycle == nil {
            activity = try Activity.request(
                attributes: CarGaugeAttributes(source: source),
                content: content(for: coolant, level: level),
                pushType: nil
            )
            lastActivityUpdate = coolant.timestamp
        } else {
            // Wait for the previous Activity to finish before requesting another one.
            startPending = true
            enqueue { [weak self] in
                guard let self, self.generation == session else { return }
                self.startPending = false
                do {
                    guard self.isForeground else { throw PresentationError.needsForeground }
                    guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PresentationError.activitiesDisabled }
                    guard coolant.isFresh(at: Date()) else { throw PresentationError.noFreshData }
                    self.activity = try Activity.request(
                        attributes: CarGaugeAttributes(source: source),
                        content: self.content(for: coolant, level: level),
                        pushType: nil
                    )
                    self.lastActivityUpdate = coolant.timestamp
                    onDeferredResult(nil)
                } catch { onDeferredResult(error) }
            }
        }
    }

    func endActivity() {
        generation += 1
        startPending = false
        let old = activity
        activity = nil
        lastActivityUpdate = nil
        if let old {
            enqueue { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) async {
        guard coolant.isFresh(at: Date()) else {
            await markActivityStale()
            return
        }
        let changed = lastPublishedLevel != level || lastPublishedSource != source
        lastPublishedLevel = level
        lastPublishedSource = source

        if changed || (lastWidgetWrite.map { coolant.timestamp.timeIntervalSince($0) >= 60 } ?? true) {
            let snapshot = WidgetSnapshot(source: source, temperature: Int(coolant.value),
                                          sampleDate: coolant.timestamp, level: level)
            if WidgetSnapshotStore.write(snapshot) {
                lastWidgetWrite = coolant.timestamp
                WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot")
            }
        }

        let session = generation
        let update = content(for: coolant, level: level)
        let shouldUpdate = changed || (lastActivityUpdate.map { coolant.timestamp.timeIntervalSince($0) >= 8 } ?? true)
        guard shouldUpdate, hasActivity else { return }
        lastActivityUpdate = coolant.timestamp
        let task = enqueue { [weak self] in
            guard let self, self.generation == session, self.hasActivity, let activity = self.activity else { return }
            await activity.update(update)
        }
        await task.value
    }

    func markActivityStale() async {
        // Clearing the snapshot also prevents an old reading appearing current in the widget.
        clearWidget()
        lastActivityUpdate = nil
        if startPending {
            generation += 1
            startPending = false
        }
        let session = generation
        let task = enqueue { [weak self] in
            guard let self, self.generation == session, self.hasActivity, let activity = self.activity else { return }
            await activity.update(ActivityContent(state: activity.content.state, staleDate: .now))
        }
        await task.value
    }

    func clearWidget() {
        lastWidgetWrite = nil
        lastPublishedLevel = nil
        lastPublishedSource = nil
        if WidgetSnapshotStore.clear() { WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot") }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lifecycle
        let id = UUID()
        lifecycleID = id
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            if self?.lifecycleID == id {
                self?.lifecycle = nil
                self?.lifecycleID = nil
            }
        }
        lifecycle = task
        return task
    }

    private var lifecycleID: UUID?

    private func content(for reading: Reading, level: ThermalLevel) -> ActivityContent<CarGaugeAttributes.ContentState> {
        let state = CarGaugeAttributes.ContentState(coolant: Int(reading.value), sampleDate: reading.timestamp, level: level)
        return ActivityContent(state: state, staleDate: reading.timestamp.addingTimeInterval(20), relevanceScore: 0)
    }

    private enum PresentationError: LocalizedError {
        case activitiesDisabled, noFreshData, needsForeground
        var errorDescription: String? {
            switch self {
            case .activitiesDisabled: "Разрешите Live Activities для CarGauge в настройках iPhone."
            case .noFreshData: "Дождитесь свежего показания температуры."
            case .needsForeground: "Откройте CarGauge, чтобы запустить Live Activity."
            }
        }
    }
}
