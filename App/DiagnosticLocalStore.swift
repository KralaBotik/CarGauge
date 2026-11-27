import CarGaugeCore
import Foundation

struct DiagnosticLocalStore {
    private var directory: URL {
        URL.applicationSupportDirectory.appending(path: "VehicleDiagnostics", directoryHint: .isDirectory)
    }

    func save(_ report: DiagnosticReport) throws {
        guard report.source == "vehicle" else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(report)
        try data.write(to: directory.appending(path: report.id.uuidString + ".json"),
                       options: [.atomic, .completeFileProtection])
    }

    func latest() -> DiagnosticReport? {
        let keys = Set([URLResourceKey.contentModificationDateKey, .isRegularFileKey])
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let candidates = entries.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in candidates {
            if let data = try? Data(contentsOf: url), data.count <= 524_288,
               let report = try? JSONDecoder().decode(DiagnosticReport.self, from: data),
               report.schemaVersion == DiagnosticReport.currentSchema, report.source == "vehicle" {
                return report.recoveredAfterRestart()
            }
        }
        return nil
    }
}
