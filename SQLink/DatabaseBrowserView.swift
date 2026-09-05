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
            } else if loading {
                ProgressView("连接中…")
            } else if let conn = connection {
                List {
                    NavigationLink("新建查询", destination: QueryConsoleView(connection: conn, db: nil))
                        .foregroundColor(.accentColor)
                    ForEach(filtered, id: \.self) { db in
                        NavigationLink(db, destination: TableListView(profile: profile, db: db, connection: conn))
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(profile.name)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索数据库")
            }
        }
        .task { await connect() }
    }

    func connect() async {
        loading = true; error = nil
        do {
            let conn = MySQLConnection(profile: profile)
            try await conn.connect(password: store.password(for: profile))
            let dbs = try await conn.listDatabases()
            await MainActor.run {
                self.connection = conn
                self.databases = dbs
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
    @State private var tables: [(name: String, type: String)] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""

    private var filtered: [(name: String, type: String)] {
        search.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let error = error {
                Text(error).foregroundColor(.red).padding()
            } else {
                List {
                    NavigationLink("新建查询（库：\(db)）", destination: QueryConsoleView(connection: connection, db: db))
                        .foregroundColor(.accentColor)
                    ForEach(0..<filtered.count, id: \.self) { i in
                        let t = filtered[i]
                        NavigationLink(destination: TableDetailView(connection: connection, db: db, table: t.name)) {
                            Label(t.name, systemImage: t.type == "VIEW" ? "eye" : "table")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(db)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索表")
            }
        }
        .task { await load() }
    }

    func load() async {
        do {
            let t = try await connection.listTables(db: db)
            await MainActor.run { self.tables = t }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }
}

// MARK: - Table detail (structure + preview)
struct TableDetailView: View {
    let connection: MySQLConnection
    let db: String
    let table: String
    @State private var columns: [ColumnInfo] = []
    @State private var previewCols: [ColumnDef] = []
    @State private var previewRows: [[String?]] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section("结构（\(columns.count) 列）") {
                if columns.isEmpty {
                    Text("加载中…").foregroundColor(.secondary)
                }
                ForEach(columns) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.field).bold()
                            Spacer()
                            if !c.key.isEmpty && c.key != " " {
                                Text(c.key).font(.caption).padding(.horizontal, 6)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                        }
                        Text("\(c.type)  \(c.null == "NO" ? "NOT NULL" : "NULL")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Section("数据预览（前 100 行）") {
                if loading {
                    ProgressView()
                } else if let error = error {
                    Text(error).foregroundColor(.red)
                } else if previewRows.isEmpty {
                    Text("无数据").foregroundColor(.secondary)
                } else {
                    ResultGridView(columns: previewCols, rows: previewRows)
                }
            }
            Section {
                NavigationLink("打开查询控制台", destination: QueryConsoleView(connection: connection, db: db))
            }
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    func load() async {
        do {
            async let cols = connection.listColumns(db: db, table: table)
            async let prev = connection.preview(db: db, table: table, limit: 100)
            let c = try await cols
            let p = try await prev
            var pc = [ColumnDef](); var pr = [[String?]]()
            if case .result(let cc, let rr) = p { pc = cc; pr = rr }
            await MainActor.run {
                self.columns = c
                self.previewCols = pc
                self.previewRows = pr
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }
}
