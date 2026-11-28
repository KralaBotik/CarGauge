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
        await refresh(ledger)
        return ledger
    }

    func refresh() async {
        do { await refresh(try await archive.maintenanceWithoutAttachments()) }
        catch { noticeMessage = error.localizedDescription }
    }

    private func refresh(_ ledger: MaintenanceLedger) async {
        do {
            if let anchor = ledger.latestOdometer {
                usage = try await archive.maintenanceUsageDetail(after: anchor.date)
            } else {
                usage = nil
            }
            let observed = MaintenanceUsage(distanceKm: usage?.kilometres, engineHours: usage?.observedSeconds.map { $0 / 3600 })
            let items = MaintenanceDueEvaluator.statuses(ledger: ledger, current: ledger.odometerCounters(observed: observed))
            next = items.first { $0.state.canRemind } ?? items.first { $0.state != .unknownHistory }
            if !testData { try await synchronize(items, preferences: ledger.settings) }
        } catch { noticeMessage = error.localizedDescription }
    }

    private func synchronize(_ due: [MaintenanceDue], preferences: MaintenanceSettings) async throws {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let existing = Set(pending.map(\.identifier).filter { $0.hasPrefix("service-calendar-") })
        guard preferences.notify else {
            center.removePendingNotificationRequests(withIdentifiers: Array(existing))
            noticeMessage = nil
            return
        }
        let permission = await center.notificationSettings().authorizationStatus
        guard permission == .authorized || permission == .provisional else {
            noticeMessage = "Уведомления обслуживания выключены в настройках iOS."
            return
        }
        let now = Date.now
        let calendar = Calendar.current
        var future: [(Date, String, MaintenanceDue)] = []
        for item in due {
            guard let date = item.dueDate, !item.approximate, item.state != .unknownHistory else { continue }
            let day = calendar.startOfDay(for: date)
            var offsets = Set([0, 1])
            offsets.insert(-preferences.leadDays)
            for offset in offsets {
                guard let day = calendar.date(byAdding: .day, value: offset, to: day),
                      let scheduled = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day), scheduled > now else { continue }
                let id = "service-calendar-\(item.id)-\(item.recordID?.uuidString ?? "rule")-\(Int(day.timeIntervalSince1970))"
                future.append((scheduled, id, item))
            }
        }
        let limited = future.sorted { $0.0 < $1.0 }.prefix(24)
        let desired = Set(limited.map { $0.1 })
        center.removePendingNotificationRequests(withIdentifiers: Array(existing.subtracting(desired)))
        for (scheduled, id, item) in limited where !existing.contains(id) {
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
        for item in due.prefix(24) where item.state.canRemind {
            let anchor = item.recordID?.uuidString ?? "rule"
            let id = "service-due-\(item.id)-\(anchor)-\(item.state.rawValue)"
            guard try await archive.reserveNotice(id, at: now) else { continue }
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
