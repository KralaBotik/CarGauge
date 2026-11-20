import ActivityKit
import CarGaugeCore
import Foundation

struct CarGaugeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let coolant: Int
        let sampleDate: Date
        let level: ThermalLevel
    }

    let source: DataSource
}

struct WidgetSnapshot: Codable {
    let source: DataSource
    let temperature: Int
    let sampleDate: Date
    let level: ThermalLevel

    // The widget is a dated snapshot. Its reloads are scheduled by WidgetKit.
    var expiration: Date { sampleDate.addingTimeInterval(15 * 60) }
}

enum WidgetSnapshotStore {
    private static var file: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CarGaugeAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("coolant-widget.json")
    }

    static func read() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let file, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
