import SwiftUI

// MARK: - Database list
struct DatabaseBrowserView: View {
    let profile: ConnectionProfile
    @EnvironmentObject var store: ConnectionStore
    @State private var connection: MySQLConnection?
    @State private var databases: [String] = []
    @State private var error: String?
    @State private var loading = true
    @State private var search = ""
    @State private var selectedDB: String? = nil
    /// 正在建立的连接：取消时直接关掉，避免 socket 挂着等超时。
    @State private var connectingConn: MySQLConnection?
    @Environment(\.dismiss) private var dismiss

    /// 有缓存会话时直接用它的数据当初始值，避免重建视图时先闪一帧「正在连接」。
    init(profile: ConnectionProfile) {
        self.profile = profile
        let cached = ConnectionPool.shared.connection(for: profile.id)
        _connection = State(initialValue: cached)
        _databases = State(initialValue: ConnectionPool.shared.databases(for: profile.id) ?? [])
        _selectedDB = State(initialValue: profile.database.isEmpty ? nil : profile.database)
        _loading = State(initialValue: cached == nil)
    }

    private var filtered: [String] {
        search.isEmpty ? databases : databases.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if let error = error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundColor(.orange)
                    Text(error).multilineTextAlignment(.center).padding(.horizontal)
                    Button("重试") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                }.padding()
            } else if let conn = connection {
                if let db = selectedDB {
                    TableListView(profile: profile, db: db, connection: conn, onSwitchDB: { selectedDB = nil })
                } else {
                    // 搜索框常驻 + 卡片自绘（原因见 Components.swift 的 CardListMetrics 注释）
                    SearchableCardList(search: $search, placeholder: "搜索数据库",
                                       isEmpty: filtered.isEmpty, emptyText: "没有匹配的数据库") {
                        ForEach(filtered.indices, id: \.self) { i in
                            CardRow(title: filtered[i],
                                    destination: TableListView(profile: profile, db: filtered[i], connection: conn))
                            if i != filtered.count - 1 { CardRowDivider() }
                        }
                    }
                    .navigationTitle(profile.name)
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                // 只有「本次真的需要新建连接」时才出现；已连上的会话会直接复用，不再闪这个界面。
                // 主机不可达时 connect 有 5 秒超时，期间可取消。
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在连接 \(profile.host):\(profile.port)")
                        .font(.footnote).foregroundColor(.secondary)
                    Button("取消") {
                        connectingConn?.close()
                        dismiss()
                    }
                    .font(.footnote)
                }
                .padding()
            }
        }
        .task { await prepare() }
        .onAppear { UserDefaults.standard.set(profile.id.uuidString, forKey: "lastConnectionID") }
    }

    /// 有可复用会话就立刻出界面（后台静默刷新库列表），否则才真正建连。
    func prepare() async {
        if let cached = connection ?? ConnectionPool.shared.connection(for: profile.id) {
            // 静默刷新：失败不打扰用户，后续查询会经 withReconnect 自动重连
            if let dbs = try? await withReconnect(cached, { try await cached.listDatabases() }) {
                await MainActor.run { self.databases = dbs }
                ConnectionPool.shared.setDatabases(dbs, for: profile.id)
            }
            await MainActor.run { self.loading = false }
            return
        }
        await connect()
    }

    func connect() async {
        loading = true; error = nil
        do {
            let conn = MySQLConnection(profile: profile)
            connectingConn = conn
            try await conn.connect(password: store.password(for: profile))
            let dbs = try await conn.listDatabases()
            ConnectionPool.shared.store(conn, databases: dbs, for: profile.id)
            await MainActor.run {
                self.connection = conn
                self.databases = dbs
                if !profile.database.isEmpty {
                    self.selectedDB = profile.database
                }
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }
}

// MARK: - Table list within a database
struct TableListView: View {
    let profile: ConnectionProfile
    let db: String
    let connection: MySQLConnection
    var onSwitchDB: (() -> Void)? = nil
    @EnvironmentObject var settings: AppSettings
    @State private var tables: [(name: String, type: String)] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""

    /// 命中缓存时先显示上次的表列表（返回上一级不再闪空白转圈），再静默刷新。
    init(profile: ConnectionProfile, db: String, connection: MySQLConnection, onSwitchDB: (() -> Void)? = nil) {
        self.profile = profile
        self.db = db
        self.connection = connection
        self.onSwitchDB = onSwitchDB
        let cached = ConnectionPool.shared.tables(for: profile.id, db: db)
        _tables = State(initialValue: cached ?? [])
        _loading = State(initialValue: cached == nil)
    }

    private var filtered: [(name: String, type: String)] {
        search.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            // 刷新时保留已有列表，避免每次返回都先闪一屏空白转圈
            if loading && tables.isEmpty {
                ProgressView()
            } else if let error = error {
                Text(error).foregroundColor(.red).padding()
            } else {
                // 表用 table 图标、视图用 eye 图标；行高与内边距由 CardRow 统一控制
                SearchableCardList(search: $search, placeholder: "搜索表",
                                   isEmpty: filtered.isEmpty, emptyText: "没有匹配的表") {
                    ForEach(filtered.indices, id: \.self) { i in
                        let t = filtered[i]
                        CardRow(icon: t.type == "VIEW" ? "eye" : "table", title: t.name,
                                destination: TableDetailView(connection: connection, db: db, table: t.name))
                        if i != filtered.count - 1 { CardRowDivider() }
                    }
                }
                .navigationTitle(db)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if let onSwitchDB = onSwitchDB {
                            Button("切换库") { onSwitchDB() }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink {
                            QueryConsoleView(connection: connection, db: db, defaultTable: nil)
                        } label: {
                            HStack(spacing: 4) {
                                if !settings.isPro {
                                    Image(systemName: "lock.fill").font(.caption2)
                                }
                                Text("查询")
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    func load() async {
        do {
            let t = try await withReconnect(connection) { try await connection.listTables(db: db) }
            ConnectionPool.shared.setTables(t, for: profile.id, db: db)
            await MainActor.run { self.tables = t }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }
}
