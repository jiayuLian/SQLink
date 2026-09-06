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

    @EnvironmentObject var settings: AppSettings

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

    // edit-from-result
    @State private var canEdit = false
    @State private var editMode = false
    @State private var editTable = ""
    @State private var editDB = ""
    @State private var editColumns: [ColumnInfo] = []
    @State private var editPK: String? = nil
    @State private var editPKIndex: Int? = nil
    @State private var editingRows: [[String?]] = []
    @State private var hasChanges = false
    @State private var editMessage: String? = nil
    @State private var editError: String? = nil

    @State private var lastExecutedSQL: String? = nil

    /// 查询结果表格双指缩放（外滑放大、内滑缩小，双击复位）。
    @State private var gridScale: CGFloat = 1.0
    @GestureState private var gridMagnify: CGFloat = 1.0

    private var currentDB: String? { db }

    /// 按「数据库 + 表」分别记忆上次输入的 SQL（自动保存开关控制）。
    private var sqlKey: String { "sqlink.sql.\(db ?? "_").\(defaultTable ?? "_")" }

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

            // autocomplete chips
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

            // run / edit / message toolbar
            Divider()
            HStack {
                Button { Task { await run() } } label: {
                    if running { ProgressView() } else { Label("运行", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
                if canEdit {
                    Spacer().frame(width: 8)
                    if editMode {
                        Button { cancelConsoleEdit() } label: { Label("取消", systemImage: "xmark") }
                        Button { Task { await saveConsoleEdits() } } label: { Label("保存", systemImage: "checkmark") }
                            .disabled(!hasChanges)
                    } else {
                        Button { enterConsoleEdit() } label: { Label("编辑", systemImage: "square.and.pencil") }
                    }
                }
                Spacer()
                if let message = message {
                    Text(message).font(.footnote).foregroundColor(message.contains("成功") || message.contains("返回") ? .primary : .red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if let editMessage = editMessage {
                Text(editMessage).font(.footnote).foregroundColor(.green).padding(.horizontal, 12).padding(.top, 2)
            }

            Divider().padding(.vertical, 6)

            // results area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("resultTop")
                        if columns.isEmpty && rows.isEmpty {
                            Text("运行 SQL 后在此显示结果").foregroundColor(.secondary).padding(.top, 40)
                        } else if editMode {
                            EditableGridView(columns: editColumns, rows: $editingRows,
                                             originalRows: rows, scale: gridScale * gridMagnify,
                                             onChange: { hasChanges = true })
                                .frame(height: 320)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    MagnificationGesture()
                                        .updating($gridMagnify) { value, state, _ in state = value }
                                        .onEnded { value in
                                            gridScale = min(max(gridScale * value, 0.6), 3.0)
                                        }
                                )
                                .onTapGesture(count: 2) { gridScale = 1 }
                        } else {
                            ResultGridView(columns: columns, rows: rows, scale: gridScale * gridMagnify)
                                .frame(height: 320)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    MagnificationGesture()
                                        .updating($gridMagnify) { value, state, _ in state = value }
                                        .onEnded { value in
                                            gridScale = min(max(gridScale * value, 0.6), 3.0)
                                        }
                                )
                                .onTapGesture(count: 2) { gridScale = 1 }
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
        .toolbar { queryToolbar }
        .sheet(isPresented: $showHistory) {
            QueryHistorySheet(history: $history) { q in
                sql = q
                showHistory = false
            }
        }
        .onAppear {
            if settings.autoSaveSQL {
                let saved = UserDefaults.standard.string(forKey: sqlKey) ?? ""
                if !saved.isEmpty { sql = saved }
            }
        }
        .onDisappear {
            if settings.autoSaveSQL {
                UserDefaults.standard.set(sql, forKey: sqlKey)
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
        .alert("提示", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("确定") { editError = nil }
        } message: { Text(editError ?? "") }
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

    private func exportAs(_ format: ExportFormat) {
        guard !columns.isEmpty else { return }
        // 免费版限制导出行数；会员无限制。
        let rowsToExport = settings.isPro ? rows : Array(rows.prefix(settings.plan.freeExportLimit))
        let names = columns.map { $0.name }
        let ts = ExportUtils.timestamp()
        let fileName: String
        let content: String
        switch format {
        case .csv:
            fileName = "query_result_\(ts).csv"
            content = ExportUtils.buildCSV(columnNames: names, rows: rowsToExport)
        case .sql:
            fileName = "query_result_\(ts).sql"
            content = ExportUtils.buildSQL(insertInto: "query_result", columnNames: names, rows: rowsToExport)
        }
        if let url = ExportUtils.writeTempFile(name: fileName, content: content) {
            ExportUtils.shareFile(url)
        }
    }

    @ToolbarContentBuilder
    private var queryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") { hideKeyboard() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { history = QueryHistory.load(); showHistory = true } label: { Image(systemName: "clock") }
        }
        // 导出：所有用户可用；免费版按免费额度限制行数，会员无限制。
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { exportAs(.csv) } label: { Label("导出 CSV", systemImage: "doc") }
                Button { exportAs(.sql) } label: { Label("导出 SQL", systemImage: "swiftdata") }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
        }
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

    /// Replaces only the current word with the suggestion.
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
            await MainActor.run { message = "请输入 SQL"; running = false }
            return
        }
        QueryHistory.add(sql)
        // 单条 SELECT 才尝试判定「可编辑」
        let single = stmts.count == 1 ? String(stmts[0]) : nil
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
                self.lastExecutedSQL = single
                self.editMode = false
                self.editingRows = []
                self.editMessage = nil
            }
            if let s = single, !lastCols.isEmpty {
                await tryDetectEditable(sql: s)
            } else {
                await MainActor.run { self.canEdit = false }
            }
        } catch {
            let msg = "错误：\(error.localizedDescription)"
            await MainActor.run { self.message = msg; self.canEdit = false }
        }
        await MainActor.run { running = false }
    }

    // MARK: - Edit from result (single-table simple SELECT only)

    private func enterConsoleEdit() {
        editingRows = rows.map { $0.map { $0 } }
        hasChanges = false
        editMessage = nil; editError = nil
        editMode = true
    }

    private func cancelConsoleEdit() {
        editMode = false
        editingRows = []
        hasChanges = false
        editMessage = nil; editError = nil
    }

    private func saveConsoleEdits() async {
        guard let pk = editPK, let pkIndex = editPKIndex else {
            await MainActor.run { editError = "未检测到主键或唯一键" }
            return
        }
        do {
            for ri in 0..<editingRows.count {
                var sets: [String] = []
                for ci in 0..<editColumns.count {
                    let old = rows[ri][ci]
                    let new = editingRows[ri][ci]
                    if old != new {
                        let col = "`\(editColumns[ci].field.replacingOccurrences(of: "`", with: "``"))`"
                        if let v = new {
                            sets.append("\(col) = \(quoteVal(v))")
                        } else {
                            sets.append("\(col) = NULL")
                        }
                    }
                }
                guard !sets.isEmpty else { continue }
                let pkVal = quoteVal(rows[ri][pkIndex] ?? "")
                let sqlUpd = "UPDATE `\(editDB.replacingOccurrences(of: "`", with: "``"))`.`\(editTable.replacingOccurrences(of: "`", with: "``"))` SET \(sets.joined(separator: ", ")) WHERE `\(pk.replacingOccurrences(of: "`", with: "``"))` = \(pkVal) LIMIT 1"
                _ = try await connection.query(sqlUpd)
            }
            await MainActor.run {
                editMessage = "保存成功"
                editError = nil
                editMode = false
                rows = editingRows
            }
        } catch {
            await MainActor.run { editError = "保存失败：\(error.localizedDescription)" }
        }
    }

    private func quoteVal(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 检测当前查询结果是否来自「单表简单 SELECT」，以便开启内联编辑。
    private func tryDetectEditable(sql raw: String) async {
        let sql = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = "(?i)\\b(join|union|group\\s+by|having|limit|offset|into|update|delete|insert|replace)\\b"
        guard sql.range(of: forbidden, options: .regularExpression) == nil else {
            await MainActor.run { canEdit = false }; return
        }
        guard sql.lowercased().hasPrefix("select") else {
            await MainActor.run { canEdit = false }; return
        }
        guard let fromRange = sql.range(of: "(?i)\\bfrom\\b", options: .regularExpression) else {
            await MainActor.run { canEdit = false }; return
        }
        var rest = String(sql[fromRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var tableName: String
        if rest.hasPrefix("`") {
            if let end = rest.dropFirst().firstIndex(of: "`") {
                tableName = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else { await MainActor.run { canEdit = false }; return }
        } else {
            let parts = rest.split(separator: " ", maxSplits: 1)
            tableName = String(parts.first ?? "")
            rest = parts.count > 1 ? String(parts[1]) : ""
        }
        if tableName.isEmpty { await MainActor.run { canEdit = false }; return }
        let restTrim = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if restTrim.hasPrefix(",") || restTrim.contains(" join ") {
            await MainActor.run { canEdit = false }; return
        }
        var useDB = db ?? ""
        if tableName.contains(".") {
            let comps = tableName.components(separatedBy: ".")
            if comps.count == 2 {
                useDB = comps[0].replacingOccurrences(of: "`", with: "")
                tableName = comps[1].replacingOccurrences(of: "`", with: "")
            }
        }
        guard !useDB.isEmpty else { await MainActor.run { canEdit = false }; return }
        do {
            let cols = try await connection.listColumns(db: useDB, table: tableName)
            guard !cols.isEmpty else { await MainActor.run { canEdit = false }; return }
            let pk = cols.first { $0.key == "PRI" }?.field ?? cols.first { $0.key == "UNI" }?.field
            guard let pk = pk else { await MainActor.run { canEdit = false }; return }
            let fieldSet = Set(cols.map { $0.field.lowercased() })
            let resultNames = columns.map { $0.name.lowercased() }
            guard resultNames.allSatisfy({ fieldSet.contains($0) }) else {
                await MainActor.run { canEdit = false }; return
            }
            let editCols = columns.compactMap { cn in cols.first { $0.field.lowercased() == cn.name.lowercased() } }
            guard editCols.count == columns.count else { await MainActor.run { canEdit = false }; return }
            let sqlHasWhere = sql.lowercased().range(of: "(?i)\\bwhere\\b", options: .regularExpression) != nil
            await MainActor.run {
                self.editTable = tableName
                self.editDB = useDB
                self.editColumns = editCols
                self.editPK = pk
                self.editPKIndex = editCols.firstIndex { $0.field == pk }
                // 数据编辑：必须是会员，且查询须带 WHERE 条件（整表 SELECT 不可编辑）
                self.canEdit = settings.isPro && sqlHasWhere
            }
        } catch {
            await MainActor.run { canEdit = false }
        }
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
