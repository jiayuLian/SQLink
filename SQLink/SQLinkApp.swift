import SwiftUI

@main
struct SQLinkApp: App {
    @StateObject private var store = ConnectionStore()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.isLoggedIn {
                    TabView {
                        ConnectionsView()
                            .tabItem { Label("数据库", systemImage: "server.rack") }
                        ProfileView()
                            .tabItem { Label("我的", systemImage: "person.circle") }
                    }
                } else {
                    AuthView()
                }
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
        guard settings.isLoggedIn, !settings.authToken.isEmpty else { return }
        // 公开配置与会员状态并行刷新
        async let plan: () = settings.refreshPlan()
        do {
            let data = try await AuthService.shared.fetchMembership(baseURL: settings.apiBaseURL, token: settings.authToken)
            await MainActor.run {
                if let email = data.email { settings.authEmail = email }
                if let nickname = data.nickname { settings.nickname = nickname }
                settings.isPro = data.isPro
                settings.proExpiresAt = data.expiresAt ?? ""
                settings.avatarURL = data.avatar ?? ""
            }
        } catch {
            // 服务器不可达 / token 过期：用本地缓存兜底，避免已付费会员被误判为免费
            await MainActor.run { settings.isPro = settings.resolveProFallback() }
            print("刷新会员状态失败（已启用本地兜底）：\(error.localizedDescription)")
        }
        _ = await plan
    }
}
