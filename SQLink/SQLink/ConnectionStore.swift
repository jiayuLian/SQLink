import SwiftUI

/// Persists connection profiles (without passwords) and bridges passwords to Keychain.
final class ConnectionStore: ObservableObject {
    @Published var profiles: [ConnectionProfile] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("connections.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return }
        profiles = arr
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: fileURL)
        }
    }

    func add(_ p: ConnectionProfile, password: String) {
        profiles.append(p)
        KeychainHelper.save(password: password, for: p.id)
        save()
    }

    func update(_ p: ConnectionProfile, password: String?) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
        }
        if let pw = password, !pw.isEmpty {
            KeychainHelper.save(password: pw, for: p.id)
        }
        save()
    }

    func remove(_ p: ConnectionProfile) {
        profiles.removeAll { $0.id == p.id }
        KeychainHelper.delete(for: p.id)
        save()
    }

    func password(for p: ConnectionProfile) -> String {
        KeychainHelper.load(for: p.id) ?? ""
    }
}
