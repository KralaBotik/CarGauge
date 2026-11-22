import AppIntents
import Combine
import Foundation

@MainActor
final class InstrumentNavigation: ObservableObject {
    static let shared = InstrumentNavigation()
    @Published private(set) var revision = 0

    func showInstruments() { revision &+= 1 }
}

struct OpenInstrumentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть приборы"
    static let description = IntentDescription("Показывает приборы CarGauge. Если включено автоподключение, приложение использует сохранённый адаптер.")

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @available(*, deprecated)
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        InstrumentNavigation.shared.showInstruments()
        return .result()
    }
}

struct CarGaugeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenInstrumentsIntent(),
            phrases: ["Открой приборы в \(.applicationName)"],
            shortTitle: "Открыть приборы",
            systemImageName: "gauge.with.dots.needle.33percent"
        )
    }
}
