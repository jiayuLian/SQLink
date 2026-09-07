import SwiftUI

@main
struct SQLinkApp: App {
    @StateObject private var store = ConnectionStore()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                ConnectionsView()
                    .tabItem { Label("数据库", systemImage: "server.rack") }
                ProfileView()
                    .tabItem { Label("我的", systemImage: "person.circle") }
            }
            .preferredColorScheme(settings.theme == .dark ? .dark : .light)
            .environmentObject(store)
            .environmentObject(settings)
            .task { await refreshMembershipIfNeeded() }
            .onChange(of: settings.isLoggedIn) { _ in
                Task { await refreshMembershipIfNeeded() }
            }
        }
    }

    private func refreshMembershipIfNeeded() async {
        await settings.refreshMembership()
    }
}
