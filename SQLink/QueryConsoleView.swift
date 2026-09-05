import SwiftUI
import UIKit

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct QueryConsoleView: View {
    let connection: MySQLConnection
    let db: String?
    let defaultTable: String?

    @State private var sql = ""
    @State private var columns: [ColumnDef] = []
    @State private var rows: [[String?]] = []
    @State private var message: String?
    @State private var running = false

    // context for autocomplete
    @State private var tables: [String] = []
    @State private var contextTable: String = ""
    @State private var contextColumns: [ColumnInfo] = []

    // query history
    @State private var showHistory = false
    @State private var history: [String] = []

    private var currentDB: String? { db }

    // autocomplete
    private let keywords = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "DROP", "ALTER", "TABLE", "DATABASE", "LIMIT", "ORDER", "GROUP", "BY",
        "AND", "OR", "NOT", "NULL", "LIKE", "IN", "BETWEEN", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "ON", "AS", "ASC", "DESC", "HAVING", "UNION", "DISTINCT",
        "COUNT", "SUM", "AVG", "MAX", "MIN"
    ]

    /// The word currently being typed (text after the last whitespace boundary).
    private var currentWord: String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let r = trimmed.range(of: " ", options: .backwards) {
            return String(trimmed[r.upperBound...])
        }
        return trimmed
    }

    /// Suggestions = keywords + table names + current-table columns, all filtered
    /// by the prefix of the current word (case-insensitive).
    private var suggestions: [String] {
        let w = currentWord.uppercased()
        guard !w.isEmpty else { return [] }
        var pool: [String] = []
        pool.append(contentsOf: keywords)
        pool.append(contentsOf: tables)
        if !contextTable.isEmpty {
            pool.append(contentsOf: contextColumns.map { $0.field })
        }
        var seen = Set<String>()
        var out: [String] = []
        for item in pool {
            let u = item.uppercased()
            if u.hasPrefix(w) && !seen.contains(u) {
                seen.insert(u)
                out.append(item)
            }
        }
        return Array(out.prefix(10))
    }

    var body: some View {
        VStack(spacing: 0) {
            // status / context bar
            HStack {
                Text(db == nil ? "未选择数据库" : "当前数据库：\(db!)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if currentDB != nil {
                    if let t = (contextTable.isEmpty ? defaultTable : contextTable), !t.isEmpty {
                        Button { insertSelectAll(table: t) } label: {
                            Image(systemName: "plus.square")
                            Text("SELECT *").font(.caption)
                        }
                        .padding(.trailing, 4)
                    }
                    Picker("上下文表", selection: $contextTable) {
                        Text("无上下文").tag("")
                        ForEach(tables, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                    .frame(maxWidth: 180)
                    .onChange(of: contextTable) { _ in loadContextColumns() }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            // SQL editor (always visible)
            TextEditor(text: $sql)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                .padding(8)

            // autocomplete chips (separated from the run button by a divider)
            if !suggestions.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { applySuggestion(s) } label: {
                                Text(s).font(.system(.subheadline, design: .monospaced))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 38)
                .padding(.bottom, 2)
            }

            // run / message toolbar
            Divider()
            HStack {
                Button { Task { await run() } } label: {
                    if running { ProgressView() } else { Label("运行", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
                Spacer()
                if let message = message {
                    Text(message).font(.footnote).foregroundColor(message.contains("成功") || message.contains("返回") ? .primary : .red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Divider().padding(.vertical, 6)

            // results area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("resultTop")
                        if columns.isEmpty && rows.isEmpty {
                            Text("运行 SQL 后在此显示结果").foregroundColor(.secondary).padding(.top, 40)
                        } else {
                            ResultGridView(columns: columns, rows: rows)
                                .frame(height: 320)
                                .padding(.horizontal, 8)
                        }
                        Color.clear.frame(height: 30).id("resultBottom")
                    }
                }
                .onChange(of: rows) { _ in
                    withAnimation { proxy.scrollTo("resultTop", anchor: .top) }
                }
            }
        }
        .navigationTitle("查询控制台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { hideKeyboard() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { history = QueryHistory.load(); showHistory = true } label: { Image(systemName: "clock") }
            }
        }
        .sheet(isPresented: $showHistory) {
            QueryHistorySheet(history: $history) { q in
                sql = q
                showHistory = false
            }
        }
        .task(id: db) {
            if let db = db {
                await loadTables(db: db)
                if let dt = defaultTable, tables.contains(dt) {
                    contextTable = dt
                    await loadContextColumnsAsync()
                }
            }
        }
    }

    private func loadTables(db: String) async {
        do {
            let list = try await connection.listTables(db: db).map { $0.name }
            await MainActor.run { self.tables = list }
        } catch {
            await MainActor.run { self.tables = [] }
        }
    }

    private func loadContextColumns() {
        Task { await loadContextColumnsAsync() }
    }

    private func loadContextColumnsAsync() async {
        guard let db = db, !contextTable.isEmpty else {
            await MainActor.run { self.contextColumns = [] }
            return
        }
        do {
            let cols = try await connection.listColumns(db: db, table: contextTable)
            await MainActor.run { self.contextColumns = cols }
        } catch {
            await MainActor.run { self.contextColumns = [] }
        }
    }

    /// Replaces only the current word (text after the last whitespace) with the
    /// suggestion, preserving everything else — so `SELECT * f` -> `SELECT * FROM `.
    private func applySuggestion(_ suggestion: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sql = suggestion + " "
            return
        }
        if let r = trimmed.range(of: " ", options: .backwards) {
            let before = String(trimmed[..<r.lowerBound])
            sql = before + " " + suggestion + " "
        } else {
            sql = suggestion + " "
        }
    }

    /// Insert a `SELECT * FROM <table>` template for the given (current) table.
    private func insertSelectAll(table: String) {
        sql = "SELECT * FROM `\(table)` "
    }

    func run() async {
        hideKeyboard()
        running = true
        let stmts = sql.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !stmts.isEmpty else {
            await MainActor.run { message = "请输入 SQL" }
            await MainActor.run { running = false }
            return
        }
        QueryHistory.add(sql)
        do {
            var lastCols: [ColumnDef] = []
            var lastRows: [[String?]] = []
            var okCount = 0
            for s in stmts {
                let r = try await connection.query(String(s))
                switch r {
                case .ok: okCount += 1; lastCols = []; lastRows = []
                case .result(let c, let rw): lastCols = c; lastRows = rw
                }
            }
            let msg = okCount > 0 && lastCols.isEmpty
                ? "执行成功（\(stmts.count) 条语句）"
                : "返回 \(lastRows.count) 行"
            await MainActor.run {
                self.columns = lastCols
                self.rows = lastRows
                self.message = msg
            }
        } catch {
            let msg = "错误：\(error.localizedDescription)"
            await MainActor.run { self.message = msg }
        }
        await MainActor.run { running = false }
    }
}

// MARK: - Query history (persisted in UserDefaults)
struct QueryHistory {
    static let key = "sqlink.queryHistory"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ sql: String) {
        let t = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = load().filter { $0 != t }
        list.insert(t, at: 0)
        if list.count > 30 { list = Array(list.prefix(30)) }
        UserDefaults.standard.set(list, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct QueryHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var history: [String]
    var onPick: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                if history.isEmpty {
                    Text("暂无查询历史").foregroundColor(.secondary)
                }
                ForEach(history, id: \.self) { q in
                    Button { onPick(q) } label: {
                        Text(q)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("查询历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { QueryHistory.clear(); history = [] }
                }
            }
        }
    }
}
