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
                }
                .padding()
                .navigationTitle(profile.name)
                .navigationBarTitleDisplayMode(.inline)
            } else if let conn = connection {
                if let db = selectedDB {
                    TableListView(profile: profile, db: db, connection: conn, onSwitchDB: { selectedDB = nil })
                } else {
                    databaseList(conn: conn)
                }
            } else {
                // 首次建连不再出「正在连接 IP:端口 / 取消」的整屏页：
                // 直接把库列表的容器铺出来（搜索框 + 空列表），连上后就地填充，
                // 只在顶部留一条 2pt 的细进度条，视觉上和「列表正在加载」一样。
                SearchableCardList(search: $search, placeholder: "搜索数据库",
                                   isEmpty: true, emptyText: " ") { EmptyView() }
                    .navigationTitle(profile.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .overlay(alignment: .top) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .allowsHitTesting(false)
                    }
            }
        }
        .task { await prepare() }
        .onAppear { UserDefaults.standard.set(profile.id.uuidString, forKey: "lastConnectionID") }
        .onDisappear {
            // 建连还没完成就退回上一级：别把 socket 挂着等超时
            if connection == nil { connectingConn?.close() }
        }
    }

    /// 库列表本体：搜索框常驻 + 卡片自绘（原因见 Components.swift 的 CardListMetrics 注释）
    private func databaseList(conn: MySQLConnection) -> some View {
        SearchableCardList(search: $search, placeholder: "搜索数据库",
                           isEmpty: filtered.isEmpty, emptyText: "没有匹配的数据库") {
            ForEach(filtered.indices, id: \.self) { i in
                CardRow(title: filtered[i],
                        destination: LazyView { TableListView(profile: profile, db: filtered[i], connection: conn) })
                if i != filtered.count - 1 { CardRowDivider() }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 有可复用会话就立刻出界面（后台静默刷新库列表），否则才真正建连。
    ///
    /// ⚠️ 不能只信 `init` 里读到的缓存：`NavigationLink(destination:)` 放在 `List` 里时，
    /// destination 这个 struct 在列表**首次渲染**时就已经构造好了（那时连接池还是空的），
    /// push 进来用的仍是那份旧 struct，`@State` 的初值就是 `nil` / 空数组
    /// （第二次进入连接时库列表一片空白、永远转不出来的根因）。
    /// 所以这里必须重新从池里取一次会话，并把结果**写回 @State**。
    func prepare() async {
        guard let cached = ConnectionPool.shared.connection(for: profile.id) else {
            // 池里确实没有会话（首次进入、或会话被丢弃）：真正建连
            await connect()
            return
        }
        // 先把缓存铺上去（同步到 @State），界面立刻有内容
        let cachedDBs = ConnectionPool.shared.databases(for: profile.id) ?? []
        await MainActor.run {
            self.connection = cached
            if self.databases.isEmpty { self.databases = cachedDBs }
            self.loading = false
        }
        // 静默刷新：失败不打扰用户（保留旧列表），后续查询会经 withReconnect 自动重连
        if let dbs = try? await withReconnect(cached, { try await cached.listDatabases() }),
           !dbs.isEmpty {
            await MainActor.run { self.databases = dbs }
            ConnectionPool.shared.setDatabases(dbs, for: profile.id)
        }
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
            if let error = error {
                VStack(spacing: 12) {
                    Text(error).foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") {
                        self.error = nil
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle(db)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                // 首次加载同样不出整屏转圈：直接给空列表 + 顶部细进度条，
                // 有缓存（返回上一级）时列表立刻就在，看起来是原地不动。
                SearchableCardList(search: $search, placeholder: "搜索表",
                                   isEmpty: filtered.isEmpty,
                                   emptyText: loading && tables.isEmpty ? " " : "没有匹配的表") {
                    // 表用 table 图标、视图用 eye 图标；行高与内边距由 CardRow 统一控制
                    ForEach(filtered.indices, id: \.self) { i in
                        let t = filtered[i]
                        CardRow(icon: t.type == "VIEW" ? "eye" : "table", title: t.name,
                                destination: LazyView {
                                    TableDetailView(connection: connection, db: db, table: t.name)
                                })
                        if i != filtered.count - 1 { CardRowDivider() }
                    }
                }
                .overlay(alignment: .top) {
                    if loading && tables.isEmpty {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .allowsHitTesting(false)
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
        // 同库列表：destination struct 可能早于缓存构造，先把池里的表列表铺上来
        if tables.isEmpty,
           let cached = ConnectionPool.shared.tables(for: profile.id, db: db), !cached.isEmpty {
            await MainActor.run {
                self.tables = cached
                self.loading = false
            }
        }
        do {
            let t = try await withReconnect(connection) { try await connection.listTables(db: db) }
            ConnectionPool.shared.setTables(t, for: profile.id, db: db)
            await MainActor.run {
                // 空结果不覆盖已有缓存（权限受限 / 响应错位时不要把列表清空）
                if !t.isEmpty || self.tables.isEmpty { self.tables = t }
                self.error = nil
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run {
                // 有缓存就当静默失败：列表照常看，别把用户已有内容换成一片红字
                self.error = self.tables.isEmpty ? msg : nil
            }
        }
        await MainActor.run { loading = false }
    }
}
