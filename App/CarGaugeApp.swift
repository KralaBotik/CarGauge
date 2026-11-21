import SwiftUI

@main struct CarGaugeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance: GaugeAppearance = .system
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            CarGaugeShell(model: model, appearance: $appearance, isActive: scenePhase == .active)
                .preferredColorScheme(appearance.scheme)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.sceneChanged(active: phase == .active, background: phase == .background)
                }
        }
    }
}

enum GaugeTab: Hashable {
    case instruments, history, diagnostics, settings
}

struct CarGaugeShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DashboardModel
    @Binding var appearance: GaugeAppearance
    let isActive: Bool
    var previewDate: Date?
    @State var tab: GaugeTab = .instruments

    var body: some View {
        let palette = GaugePalette(scheme: colorScheme)
        TabView(selection: $tab) {
            DashboardView(model: model, previewDate: previewDate, showHistory: { tab = .history },
                          showDiagnostics: { tab = .diagnostics })
                .tabItem { Label("Приборы", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(GaugeTab.instruments)
            GaugeHistoryView(model: model)
                .tabItem { Label("История", systemImage: "chart.xyaxis.line") }
                .tag(GaugeTab.history)
            GaugeDiagnosticsView(model: model)
                .tabItem { Label("Диагностика", systemImage: "waveform.path.ecg") }
                .tag(GaugeTab.diagnostics)
            GaugeSettingsView(model: model, appearance: $appearance, isActive: isActive)
                .tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }
                .tag(GaugeTab.settings)
        }
        .tint(palette.accent)
        .environment(\.gaugePalette, palette)
    }
}

#if DEBUG
#Preview("Приборы · тёмная") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now), appearance: .constant(.dark), isActive: true, previewDate: now)
        .preferredColorScheme(.dark)
}

#Preview("Приборы · светлая") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now, source: .vehicle), appearance: .constant(.light), isActive: true, previewDate: now)
        .preferredColorScheme(.light)
}

#Preview("Перегрев · крупный текст") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now, finalTemperature: 118), appearance: .constant(.dark), isActive: true, previewDate: now)
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("История") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now), appearance: .constant(.light), isActive: true, previewDate: now, tab: .history)
        .preferredColorScheme(.light)
}

#Preview("Диагностика") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now), appearance: .constant(.dark), isActive: true, previewDate: now, tab: .diagnostics)
        .preferredColorScheme(.dark)
}

#Preview("Настройки") {
    CarGaugeShell(model: DashboardModel(), appearance: .constant(.dark), isActive: true, tab: .settings)
        .preferredColorScheme(.dark)
}
#endif
