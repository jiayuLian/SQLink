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
            .task { await refreshConfigIfNeeded() }
            .onChange(of: settings.isLoggedIn) { _ in
                Task { await refreshConfigIfNeeded() }
            }
        }
    }

    private func refreshConfigIfNeeded() async {
        await settings.refreshConfig()
        // 冷启动补齐头像：本地为空（重装 / 老用户）时从服务端拉一次。
        await settings.syncAvatarFromServer()
    }
}
