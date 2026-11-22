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

private enum GaugeDestination: Hashable {
    case history, settings, diagnostics
}

struct CarGaugeShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DashboardModel
    @Binding var appearance: GaugeAppearance
    let isActive: Bool
    var previewDate: Date?
    @State private var path: [GaugeDestination] = []
    @State private var showsAdapterSetup = false

    var body: some View {
        let palette = GaugePalette(scheme: colorScheme)
        NavigationStack(path: $path) {
            DashboardView(model: model, previewDate: previewDate,
                          showHistory: { path.append(.history) },
                          showSettings: { path.append(.settings) },
                          showAdapter: { showsAdapterSetup = true })
                .navigationTitle("CarGauge")
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: GaugeDestination.self) { destination in
                    switch destination {
                    case .history:
                        GaugeHistoryView(model: model)
                            .navigationTitle("Поездка")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                    case .settings:
                        GaugeSettingsView(model: model, appearance: $appearance, isActive: isActive,
                                          showAdapter: { showsAdapterSetup = true },
                                          showDiagnostics: { path.append(.diagnostics) })
                            .navigationTitle("Настройки")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                    case .diagnostics:
                        GaugeDiagnosticsView(model: model, ble: model.ble)
                            .navigationTitle("Диагностика")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                    }
                }
        }
        .sheet(isPresented: $showsAdapterSetup) {
            GaugeAdapterSetupView(model: model)
        }
        .tint(palette.accent)
        .environment(\.gaugePalette, palette)
    }
}

#if DEBUG
#Preview("Первое открытие") {
    CarGaugeShell(model: DashboardModel(), appearance: .constant(.light), isActive: true)
        .preferredColorScheme(.light)
}

#Preview("Поездка · тёмная") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now), appearance: .constant(.dark), isActive: true, previewDate: now)
        .preferredColorScheme(.dark)
}

#Preview("Перегрев · крупный текст") {
    let now = Date.now
    CarGaugeShell(model: .preview(at: now, finalTemperature: 118), appearance: .constant(.dark),
                  isActive: true, previewDate: now)
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
