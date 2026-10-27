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
        // 主机/端口/密码可能变了，旧会话不能再复用
        ConnectionPool.shared.remove(for: p.id)
        save()
    }

    func remove(_ p: ConnectionProfile) {
        profiles.removeAll { $0.id == p.id }
        KeychainHelper.delete(for: p.id)
        ConnectionPool.shared.remove(for: p.id)
        save()
    }

    func password(for p: ConnectionProfile) -> String {
        KeychainHelper.load(for: p.id) ?? ""
    }
}

/// 已建立会话的缓存。
///
/// 背景：从「数据库列表 / 表列表 / 表详情」之间来回切换时，SwiftUI 会重建
/// `DatabaseBrowserView`，它的 `.task` 于是又跑一次 `connect()`——已经在手的
/// 连接被丢掉重新握手，用户看到的就是每次返回都弹「正在连接…」（主机不可达时
/// 还要干等十几秒）。这里按 profile.id 缓存连接与库列表，返回时直接复用。
final class ConnectionPool {
    static let shared = ConnectionPool()

    private var connections: [UUID: MySQLConnection] = [:]
    private var databaseLists: [UUID: [String]] = [:]
    private var tableLists: [String: [(name: String, type: String)]] = [:]
    private let lock = NSLock()

    func connection(for id: UUID) -> MySQLConnection? {
        lock.lock(); defer { lock.unlock() }
        return connections[id]
    }

    func databases(for id: UUID) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return databaseLists[id]
    }

    func store(_ conn: MySQLConnection, databases: [String], for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        connections[id] = conn
        databaseLists[id] = databases
    }

    func setDatabases(_ dbs: [String], for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        databaseLists[id] = dbs
    }

    /// 表列表缓存：返回上一级时先显示上次结果，再静默刷新，不会闪一屏空白。
    private func tableKey(_ id: UUID, _ db: String) -> String { "\(id.uuidString)|\(db)" }

    func tables(for id: UUID, db: String) -> [(name: String, type: String)]? {
        lock.lock(); defer { lock.unlock() }
        return tableLists[tableKey(id, db)]
    }

    func setTables(_ rows: [(name: String, type: String)], for id: UUID, db: String) {
        lock.lock(); defer { lock.unlock() }
        tableLists[tableKey(id, db)] = rows
    }

    /// 回前台探活：把缓存里的每条连接都戳一下（3 秒短超时），
    /// 已经断掉的静默重建。后台执行，不阻塞 UI，失败也不弹错。
    func revalidateAll() {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for c in all {
            Task { await c.pingAndRepair() }
        }
    }

    /// 连接资料被修改/删除时调用：丢弃旧会话，下次进入重新握手。
    func remove(for id: UUID) {
        lock.lock()
        let old = connections.removeValue(forKey: id)
        databaseLists[id] = nil
        let prefix = id.uuidString + "|"
        tableLists = tableLists.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        old?.close()
    }
}
