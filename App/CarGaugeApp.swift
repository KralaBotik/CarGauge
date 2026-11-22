import Foundation
import SwiftUI

@main struct CarGaugeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @AppStorage("appearance") private var appearance: GaugeAppearance = .system
    @StateObject private var model: DashboardModel
    private let fixtureDate: Date?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--connected-dashboard-fixture") {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            fixtureDate = date
            _model = StateObject(wrappedValue: DashboardModel.preview(at: date))
            return
        }
        #endif
        fixtureDate = nil
        _model = StateObject(wrappedValue: DashboardModel())
    }

    var body: some Scene {
        WindowGroup {
            rootView.preferredColorScheme(appearance.scheme)
        }
    }

    @ViewBuilder private var rootView: some View {
        #if DEBUG && !CARGAUGE_BASIC
        if ProcessInfo.processInfo.arguments.contains("--glance-preview-fixture") {
            GlancePreviewFixture()
        } else {
            carGauge
        }
        #else
        carGauge
        #endif
    }

    private var carGauge: some View {
        CarGaugeShell(model: model, appearance: $appearance, isActive: scenePhase == .active, previewDate: fixtureDate)
            .environment(\.locale, fixtureDate == nil ? locale : Locale(identifier: "ru_RU"))
            .onChange(of: scenePhase, initial: true) { _, phase in
                if fixtureDate == nil {
                    model.sceneChanged(active: phase == .active, background: phase == .background)
                }
            }
    }
}

private enum GaugeDestination: Hashable {
    case diagnostics
}

struct CarGaugeShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DashboardModel
    @Binding var appearance: GaugeAppearance
    let isActive: Bool
    var previewDate: Date?
    @StateObject private var navigation = InstrumentNavigation.shared
    @State private var section: GaugeMainSection = .instruments
    @State private var path: [GaugeDestination] = []
    @State private var showsAdapterSetup = false

    var body: some View {
        let palette = GaugePalette(scheme: colorScheme)
        NavigationStack(path: $path) {
            sectionView
                .navigationDestination(for: GaugeDestination.self) { destination in
                    switch destination {
                    case .diagnostics:
                        GaugeDiagnosticsView(model: model, ble: model.ble)
                            .navigationTitle("Диагностика")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GaugeNavigationBar(selection: section, select: selectSection)
        }
        .sheet(isPresented: $showsAdapterSetup) {
            GaugeAdapterSetupView(model: model)
        }
        .onChange(of: navigation.revision) { _, _ in
            selectSection(.instruments)
            showsAdapterSetup = false
        }
        .tint(palette.accent)
        .environment(\.gaugePalette, palette)
    }

    @ViewBuilder private var sectionView: some View {
        switch section {
        case .instruments:
            DashboardView(model: model, previewDate: previewDate,
                          showHistory: { selectSection(.history) }, showAdapter: { showsAdapterSetup = true })
                .navigationTitle("Приборы")
                .toolbar(.hidden, for: .navigationBar)
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
        }
    }

    private func selectSection(_ destination: GaugeMainSection) {
        path = []
        section = destination
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
