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
                if let db = selectedDB {
                    TableListView(profile: profile, db: db, connection: conn, onSwitchDB: { selectedDB = nil })
                } else {
                    List {
                        NavigationLink("新建查询", destination: QueryConsoleView(connection: conn, db: nil, defaultTable: nil))
                            .foregroundColor(.accentColor)
                        ForEach(filtered, id: \.self) { db in
                            NavigationLink(db, destination: TableListView(profile: profile, db: db, connection: conn))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle(profile.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索数据库")
                }
            }
        }
        .task { await connect() }
        .onAppear { UserDefaults.standard.set(profile.id.uuidString, forKey: "lastConnectionID") }
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
                    NavigationLink("新建查询（库：\(db)）", destination: QueryConsoleView(connection: connection, db: db, defaultTable: nil))
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
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索表")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if let onSwitchDB = onSwitchDB {
                            Button("切换库") { onSwitchDB() }
                        }
                    }
                }
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
