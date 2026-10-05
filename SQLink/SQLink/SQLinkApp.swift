import SwiftUI

@main
struct SQLinkApp: App {
    @StateObject private var store = ConnectionStore()
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showKickedAlert = false
    @State private var kickedMessage = ""

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
            .task { await handleLaunchSessionCheck() }
            .onChange(of: settings.isLoggedIn) { _ in
                Task { await settings.refreshConfig() }
            }
            // 回到前台时检测是否被其他设备挤下线（一号一用：第二台登录踢第一台）。
            // 锁屏 / 切后台后系统可能回收网络，此时戳一次后端即可感知 token 是否已失效。
            .onChange(of: scenePhase) { _ in
                if scenePhase == .active {
                    Task { await handleResumeSessionCheck() }
                }
            }
            .alert("账号已被下线", isPresented: $showKickedAlert) {
                Button("确定") {}
            } message: {
                Text(kickedMessage)
            }
        }
    }

    /// 冷启动：先校验会话（检测被踢 / 过期），再刷新公开配置。
    private func handleLaunchSessionCheck() async {
        let kicked = await settings.validateSession()
        if kicked {
            await MainActor.run {
                kickedMessage = "您的账号已在其他设备登录，当前设备已被强制下线，请重新登录。"
                showKickedAlert = true
            }
        }
        await settings.refreshConfig()
    }

    /// 回前台：检测被其他设备挤下线。
    private func handleResumeSessionCheck() async {
        let kicked = await settings.validateSession()
        if kicked {
            await MainActor.run {
                kickedMessage = "您的账号已在其他设备登录，当前设备已被强制下线，请重新登录。"
                showKickedAlert = true
            }
        }
    }
}
