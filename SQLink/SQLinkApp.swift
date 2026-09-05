import SwiftUI

@main
struct SQLinkApp: App {
    @StateObject private var store = ConnectionStore()
    var body: some Scene {
        WindowGroup {
            ConnectionsView()
                .environmentObject(store)
        }
    }
}
