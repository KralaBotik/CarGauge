import SwiftUI

@main struct CarGaugeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model, isActive: scenePhase == .active)
                .task { model.launch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshActivityState() }
                }
        }
    }
}
