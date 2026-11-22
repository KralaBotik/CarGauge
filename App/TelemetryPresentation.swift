// The iOS 26 SDK leaves Activity's async methods unannotated. This class owns the handles on MainActor.
@preconcurrency import ActivityKit
import CarGaugeCore
import Foundation
import WidgetKit

@MainActor final class TelemetryPresentation {
    private var activity: Activity<CarGaugeAttributes>?
    private var lifecycle: Task<Void, Never>?
    private var lifecycleID: UUID?
    private var generation = 0
    private var deferredStartCompletion: (@MainActor (Error?) -> Void)?
    private var pendingUpdateID: UUID?
    private var lastActivityUpdate: Date?
    private var lastActivityLevel: ThermalLevel?
    private var lastWidgetAttempt: Date?
    private var lastWidgetReload: Date?
    private var lastPublishedLevel: ThermalLevel?
    private var lastPublishedSource: DataSource?
    var isForeground = false
    var groupIsAvailable: Bool { WidgetSnapshotStore.containerIsAvailable }

    var hasActivity: Bool {
        deferredStartCompletion != nil || activity?.activityState == .active || activity?.activityState == .stale
    }

    func cleanUpPreviousRun() {
        generation += 1
        pendingUpdateID = nil
        activity = nil
        lastActivityUpdate = nil
        lastActivityLevel = nil
        cancelDeferredStart()
        let previous = Activity<CarGaugeAttributes>.activities
        enqueue {
            for item in previous { await item.end(nil, dismissalPolicy: .immediate) }
        }
        clearWidget()
    }

    func startActivity(source: DataSource,
                       latestSample: @escaping @MainActor () -> (Reading, ThermalLevel)?,
                       onDeferredResult: @escaping @MainActor (Error?) -> Void) throws {
        guard isForeground else { throw PresentationError.needsForeground }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PresentationError.activitiesDisabled }
        guard !hasActivity else { return }

        let session = generation
        if lifecycle == nil {
            guard let (coolant, level) = latestSample(), coolant.isFresh(at: Date()) else {
                throw PresentationError.noFreshData
            }
            activity = try Activity.request(
                attributes: CarGaugeAttributes(source: source),
                content: content(for: coolant, level: level),
                pushType: nil
            )
            lastActivityUpdate = coolant.timestamp
            lastActivityLevel = level
        } else {
            // Wait for the previous Activity to finish before requesting another one.
            deferredStartCompletion = onDeferredResult
            enqueue { [weak self] in
                guard let self, self.generation == session, let completion = self.deferredStartCompletion else { return }
                self.deferredStartCompletion = nil
                do {
                    guard self.isForeground else { throw PresentationError.needsForeground }
                    guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw PresentationError.activitiesDisabled }
                    guard let (coolant, level) = latestSample(), coolant.isFresh(at: Date()) else {
                        throw PresentationError.noFreshData
                    }
                    self.activity = try Activity.request(
                        attributes: CarGaugeAttributes(source: source),
                        content: self.content(for: coolant, level: level),
                        pushType: nil
                    )
                    self.lastActivityUpdate = coolant.timestamp
                    self.lastActivityLevel = level
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    func endActivity() {
        generation += 1
        pendingUpdateID = nil
        let old = activity
        activity = nil
        lastActivityUpdate = nil
        lastActivityLevel = nil
        cancelDeferredStart()
        if let old {
            enqueue { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func publish(coolant: Reading, source: DataSource, level: ThermalLevel) {
        guard coolant.isFresh(at: Date()) else {
            markActivityStale()
            return
        }
        let changed = lastPublishedLevel != level || lastPublishedSource != source
        lastPublishedLevel = level
        lastPublishedSource = source

        if changed || (lastWidgetAttempt.map { coolant.timestamp.timeIntervalSince($0) >= 30 } ?? true) {
            lastWidgetAttempt = coolant.timestamp
            let snapshot = WidgetSnapshot(source: source, temperature: Int(coolant.value),
                                          sampleDate: coolant.timestamp, level: level)
            if WidgetSnapshotStore.write(snapshot),
               changed || (lastWidgetReload.map { coolant.timestamp.timeIntervalSince($0) >= 60 } ?? true) {
                lastWidgetReload = coolant.timestamp
                WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot")
            }
        }

        let shouldUpdate = lastActivityLevel != level
            || (lastActivityUpdate.map { coolant.timestamp.timeIntervalSince($0) >= 8 } ?? true)
        guard shouldUpdate, hasActivity, pendingUpdateID == nil else { return }
        let session = generation
        let id = UUID()
        let update = content(for: coolant, level: level)
        pendingUpdateID = id
        enqueue { [weak self] in
            guard let self, self.pendingUpdateID == id else { return }
            self.pendingUpdateID = nil
            guard self.generation == session, self.hasActivity, let activity = self.activity,
                  coolant.isFresh(at: Date()) else { return }
            self.lastActivityUpdate = coolant.timestamp
            self.lastActivityLevel = level
            await activity.update(update)
        }
    }

    func markActivityStale() {
        generation += 1
        pendingUpdateID = nil
        // Clearing the snapshot also prevents an old reading appearing current in the widget.
        clearWidget()
        lastActivityUpdate = nil
        cancelDeferredStart()
        guard hasActivity else { return }
        let session = generation
        enqueue { [weak self] in
            guard let self, self.generation == session, self.hasActivity, let activity = self.activity else { return }
            await activity.update(ActivityContent(state: activity.content.state, staleDate: .now))
        }
    }

    func clearWidget() {
        lastWidgetAttempt = nil
        lastWidgetReload = nil
        lastPublishedLevel = nil
        lastPublishedSource = nil
        if WidgetSnapshotStore.clear() { WidgetCenter.shared.reloadTimelines(ofKind: "CoolantSnapshot") }
    }

    static func isRetryableStartError(_ error: any Error) -> Bool {
        guard let error = error as? PresentationError else { return false }
        return error != .activitiesDisabled
    }

    private func cancelDeferredStart() {
        let completion = deferredStartCompletion
        deferredStartCompletion = nil
        completion?(PresentationError.interrupted)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
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
    }

    private func content(for reading: Reading, level: ThermalLevel) -> ActivityContent<CarGaugeAttributes.ContentState> {
        let state = CarGaugeAttributes.ContentState(coolant: Int(reading.value), sampleDate: reading.timestamp, level: level)
        return ActivityContent(state: state, staleDate: reading.timestamp.addingTimeInterval(20), relevanceScore: 0)
    }

    private enum PresentationError: LocalizedError {
        case activitiesDisabled, noFreshData, needsForeground, interrupted
        var errorDescription: String? {
            switch self {
            case .activitiesDisabled: "Разрешите Live Activities для CarGauge в настройках iPhone."
            case .noFreshData: "Дождитесь свежего показания температуры."
            case .needsForeground: "Откройте CarGauge, чтобы запустить Live Activity."
            case .interrupted: "Запуск Live Activity прерван. Дождитесь свежего замера."
            }
        }
    }
}
