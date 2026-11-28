import CarGaugeCore
import Combine
import Foundation
import UserNotifications

@MainActor final class VehicleServicePortal: ObservableObject, MaintenanceStore {
    @Published private(set) var next: MaintenanceDue?
    @Published private(set) var usage: MaintenanceUsageDetail?
    @Published private(set) var noticeMessage: String?
    let archive: TelemetryArchive
    let testData: Bool
    private var refreshing = false
    private var refreshRequested = false

    init(archive: TelemetryArchive, testData: Bool) {
        self.archive = archive
        self.testData = testData
    }

    func readMaintenance() async throws -> MaintenanceLedger { try await archive.readMaintenance() }

    func observedMaintenanceUsage(after date: Date) async throws -> MaintenanceUsage {
        try await archive.observedMaintenanceUsage(after: date)
    }

    func applyMaintenance(_ change: MaintenanceChange) async throws -> MaintenanceLedger {
        let ledger = try await archive.applyMaintenance(change)
        if case .settings(let settings) = change, settings.notify, !testData {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .badge])
            }
        }
        await refresh()
        return ledger
    }

    func refresh() async {
        refreshRequested = true
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        while refreshRequested {
            refreshRequested = false
            do {
                let ledger = try await archive.maintenanceWithoutAttachments()
                let anchor = ledger.latestOdometer?.date ?? .distantPast
                let currentUsage = try await archive.maintenanceUsageDetail(after: anchor)
                let observed = MaintenanceUsage(distanceKm: currentUsage.kilometres,
                                                engineHours: currentUsage.observedSeconds.map { $0 / 3600 })
                let items = MaintenanceDueEvaluator.statuses(ledger: ledger, current: ledger.odometerCounters(observed: observed))
                if refreshRequested { continue }
                usage = currentUsage
                next = items.filter { $0.state != .unknownHistory }.sorted {
                    if $0.state.rank != $1.state.rank { return $0.state.rank > $1.state.rank }
                    if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
                    return $0.component.title < $1.component.title
                }.first
                if !testData { try await synchronize(items, preferences: ledger.settings) }
            } catch { noticeMessage = error.localizedDescription }
        }
    }

    private func synchronize(_ due: [MaintenanceDue], preferences: MaintenanceSettings) async throws {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard !refreshRequested else { return }
        let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix("service-calendar-") })
        guard preferences.notify else {
            center.removePendingNotificationRequests(withIdentifiers: Array(existing))
            noticeMessage = nil
            return
        }
        let permission = await center.notificationSettings().authorizationStatus
        guard !refreshRequested else { return }
        guard permission == .authorized || permission == .provisional else {
            noticeMessage = "Уведомления обслуживания выключены в настройках iOS."
            return
        }
        let now = Date.now
        let calendar = Calendar.current
        var future: [(Date, String, MaintenanceDue)] = []
        var activeCalendarStage: [String: String] = [:]
        for item in due {
            guard let date = item.dueDate, item.exactCalendarDate else { continue }
            let day = calendar.startOfDay(for: date)
            var offsets = Set([0, 1])
            offsets.insert(-preferences.leadDays)
            for offset in offsets {
                guard let day = calendar.date(byAdding: .day, value: offset, to: day),
                      let scheduled = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) else { continue }
                let id = "service-calendar-\(item.id)-\(item.recordID?.uuidString ?? "rule")-\(Int(day.timeIntervalSince1970))"
                let matchingStage = (offset < 0 && item.state == .soon)
                    || (offset == 0 && (item.state == .due || item.state == .requiresInspection))
                    || (offset > 0 && (item.state == .overdue || item.state == .requiresInspection))
                if matchingStage && (calendar.isDate(scheduled, inSameDayAs: now) || scheduled < now) {
                    activeCalendarStage[item.id] = id
                }
                if scheduled > now { future.append((scheduled, id, item)) }
            }
        }
        let limited = future.sorted { $0.0 < $1.0 }.prefix(24)
        let desired = Set(limited.map { $0.1 })
        center.removePendingNotificationRequests(withIdentifiers: Array(existing.subtracting(desired)))
        for (scheduled, id, item) in limited where !existing.contains(id) {
            guard !refreshRequested else { return }
            let content = UNMutableNotificationContent()
            content.title = "Обслуживание · \(item.component.title)"
            if let date = item.dueDate, calendar.startOfDay(for: scheduled) > calendar.startOfDay(for: date) {
                content.body = "Календарный срок прошёл. Проверьте последнее обслуживание."
            } else if let date = item.dueDate {
                content.body = "Запланированный срок \(date.formatted(date: .abbreviated, time: .omitted))."
            }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduled)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        let deliveredIDs = Set(delivered.map { $0.request.identifier })
        for item in due.prefix(24) where item.state.canRemind {
            guard !refreshRequested else { return }
            if let scheduledID = activeCalendarStage[item.id],
               desired.contains(scheduledID) || deliveredIDs.contains(scheduledID) { continue }
            let anchor = item.recordID?.uuidString ?? "rule"
            let id = "service-due-\(item.id)-\(anchor)-\(item.state.rawValue)"
            guard try await archive.reserveNotice(id, at: now) else { continue }
            guard !refreshRequested else {
                try? await archive.releaseNotice(id)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Обслуживание · \(item.component.title)"
            content.body = item.state.title
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
            catch {
                try? await archive.releaseNotice(id)
                throw error
            }
        }
        noticeMessage = nil
    }
}
