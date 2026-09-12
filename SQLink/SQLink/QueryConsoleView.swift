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
    @State private var contextTable: String = ""   // 手动从「上下文表」选择的表
    @State private var detectedTable: String = ""   // 从 SQL 文本自动解析出的表
    @State private var contextColumns: [ColumnInfo] = []
    @State private var columnCache: [String: [ColumnInfo]] = [:]  // 各表字段缓存（多表 JOIN 补全用）

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
        "SELECT", "SELECT *", "SELECT DISTINCT", "FROM", "WHERE", "AND", "OR", "NOT",
        "ORDER BY", "GROUP BY", "HAVING", "LIMIT", "OFFSET",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM",
        "CREATE TABLE", "DROP TABLE", "ALTER TABLE", "TRUNCATE TABLE",
        "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "OUTER JOIN", "ON",
        "AS", "ASC", "DESC", "LIKE", "IN", "NOT IN", "BETWEEN", "IS NULL", "IS NOT NULL",
        "NULL", "COUNT(*)", "COUNT", "SUM", "AVG", "MAX", "MIN",
        "NOW()", "CASE WHEN", "EXISTS", "UNION ALL", "UNION"
    ]

    /// 当前正在输入的「词」：最后一个空白符之后的子串。
    /// 若 SQL 以空白结尾（刚输完一个词、位于词边界），返回空串，表示应在末尾追加。
    private var currentWord: String {
        if let r = sql.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
            return String(sql[r.upperBound...])
        }
        return sql
    }

    /// Suggestions = keywords + table names + current-table columns。
    /// 过滤规则见 matchesSuggestion：前缀优先，段感知（含子串）兜底。
    /// 例：输入 lvv_c / lvv_r 都能匹配 lvv_exchange_record；输入 config 也能匹配 lvv_user_config。
    /// 特殊：输入 `别名.` 或 `表名.`（如 a. ）时，改提示该表/别名的字段名。
    /// 当「当前词」为空（刚输完一个词、位于词边界）时，展示默认候选列表。
    private var suggestions: [String] {
        // 完全空白（尚未输入任何内容）时不打扰用户
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }

        let raw = currentWord
        // 限定符引用：a. 或 table. → 提示对应表的字段
        if let dotRange = raw.lastIndex(of: ".") {
            let qual = String(raw[..<dotRange])
            let partial = String(raw[raw.index(after: dotRange)...])
            if let table = resolveQualifier(qual) {
                let cols = columnsForTable(table)
                let w = partial.uppercased()
                var seen = Set<String>()
                var out: [String] = []
                for item in cols {
                    let u = item.uppercased()
                    if w.isEmpty || matchesSuggestion(item, w), !seen.contains(u) {
                        seen.insert(u)
                        out.append(item)
                    }
                }
                return Array(out.prefix(10))
            }
        }

        // 默认：关键词 + 表名 + 当前上下文表的字段
        let w = raw.uppercased()
        var pool: [String] = []
        pool.append(contentsOf: keywords)
        pool.append(contentsOf: tables)
        if !activeContextTable.isEmpty {
            pool.append(contentsOf: contextColumns.map { $0.field })
        }
        var seen = Set<String>()
        var out: [String] = []
        for item in pool {
            let u = item.uppercased()
            if w.isEmpty || matchesSuggestion(item, w), !seen.contains(u) {
                seen.insert(u)
                out.append(item)
            }
        }
        return Array(out.prefix(10))
    }

    /// 候选词 `item` 是否匹配用户输入的「当前词」`typed`（不区分大小写）。
    /// 1. 前缀匹配：item 以 typed 开头（最精确，保留原有行为）。
    /// 2. 段感知匹配：按 `_` 拆分后，已输入的前导段需逐段前缀对齐，
    ///    最后一个输入段只需是后续任意段的「前缀或子串」。
    ///    例：lvv_c / lvv_r 均能匹配 lvv_exchange_record；输入 config 也能匹配 lvv_user_config。
    private func matchesSuggestion(_ item: String, _ typed: String) -> Bool {
        let t = typed.uppercased()
        guard !t.isEmpty else { return true }
        let i = item.uppercased()
        // 1) 前缀匹配（最精确）
        if i.hasPrefix(t) { return true }
        // 2) 段感知兜底：typed 至少 2 字符，避免单字符过度扩散
        guard t.count >= 2 else { return false }
        let tp = t.split(separator: "_").map(String.init)
        let ip = i.split(separator: "_").map(String.init)
        guard !tp.isEmpty, !ip.isEmpty else { return false }
        // 前导段（除最后一段）必须逐段前缀对齐
        for k in 0..<(tp.count - 1) {
            guard k < ip.count, ip[k].hasPrefix(tp[k]) else { return false }
        }
        // 最后一段：在 item 的剩余段中，任一段前缀或包含它即可
        let last = tp.last!
        return ip[(tp.count - 1)...].contains { $0.hasPrefix(last) || $0.contains(last) }
    }

    // MARK: - 限定符解析（别名 / 表名 + 字段补全）

    /// 从 FROM / JOIN 子句解析出 (表名, 别名?) 列表，支持多表关联查询：
    /// 多个 JOIN（INNER/LEFT/RIGHT/... JOIN）、逗号 JOIN（FROM t1, t2）均能逐表解析别名。
    private var parsedFromTables: [(table: String, alias: String?)] {
        // 1) 取出 FROM 之后的子句区域（到首个顶层 WHERE/GROUP BY/ORDER BY/HAVING/LIMIT/UNION/SET/VALUES 之前）。
        let regionPattern = #"(?is)\bfrom\b\s+(.*?)(?=\bwhere\b|\bgroup\s+by\b|\border\s+by\b|\bhaving\b|\blimit\b|\bunion\b|\bset\b|\bvalues\b|$)"#
        guard let regionRegex = try? NSRegularExpression(pattern: regionPattern, options: []),
              let rm = regionRegex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)),
              rm.numberOfRanges > 1 else { return [] }
        let region = (sql as NSString).substring(with: rm.range(at: 1))

        // 2) 在区域内按 JOIN 关键词 / 逗号 切分表引用（^ 用于紧接 FROM 的首个表）。
        //    表名必须以字母或下划线开头，避免把 IN (1,2) 里的数字误当表名。
        let refPattern = #"(?i)(?:^|(?:\b(?:inner|left|right|outer|full|cross|natural)\s+)?join\b|,)\s*`?([a-zA-Z_][a-zA-Z0-9_]*)`?(?:\.`?([a-zA-Z_][a-zA-Z0-9_]*)`?)?(?:\s+(?:as\s+)?`?([a-zA-Z_][a-zA-Z0-9_]*)`?)?"#
        guard let refRegex = try? NSRegularExpression(pattern: refPattern, options: []) else { return [] }
        let rns = region as NSString
        let mr = refRegex.matches(in: region, range: NSRange(location: 0, length: rns.length))
        // 跟在表名后的 SQL 关键词不应被当作别名
        let kw = Set(["where","on","join","left","right","inner","outer","full","cross","natural","group","order","having","limit","set","values","and","or","union","by","as","using"])
        var res: [(String, String?)] = []
        for m in mr {
            let g1 = m.range(at: 1).location != NSNotFound ? rns.substring(with: m.range(at: 1)) : ""
            let g2 = m.range(at: 2).location != NSNotFound ? rns.substring(with: m.range(at: 2)) : ""
            let g3 = m.range(at: 3).location != NSNotFound ? rns.substring(with: m.range(at: 3)) : ""
            guard !g1.isEmpty else { continue }
            let table = g2.isEmpty ? g1 : g1 + "." + g2
            var alias: String? = nil
            if !g3.isEmpty, !kw.contains(g3.lowercased()) { alias = g3 }
            res.append((table, alias))
        }
        return res
    }

    /// 将限定符（别名或表名）解析为对应的表名。
    /// 多表 JOIN 时（如 `a`/`b` 分别为两表的别名），各自解析到各自对应的表。
    private func resolveQualifier(_ qual: String) -> String? {
        let q = qual.uppercased()
        // 1) 别名优先
        for (table, alias) in parsedFromTables {
            if let a = alias, a.uppercased() == q { return table }
        }
        // 2) 表名本身，或 db.table 的末段表名
        for (table, _) in parsedFromTables {
            if table.uppercased() == q { return table }
            let parts = table.components(separatedBy: ".")
            if parts.count == 2 && parts[1].uppercased() == q { return table }
        }
        return nil
    }

    /// 取某张表的字段名列表（优先上下文表，其次缓存，必要时异步补加载）。
    /// table 可能以「db.表」形式出现，加载与查找时统一取末段表名。
    private func columnsForTable(_ table: String) -> [String] {
        let t = table.components(separatedBy: ".").last ?? table
        if t == activeContextTable, !contextColumns.isEmpty {
            return contextColumns.map { $0.field }
        }
        if let c = columnCache[t], !c.isEmpty {
            return c.map { $0.field }
        }
        Task { await loadColumnsForTable(t) }
        return (t == activeContextTable) ? contextColumns.map { $0.field } : (columnCache[t]?.map { $0.field } ?? [])
    }

    @MainActor private func loadColumnsForTable(_ table: String) async {
        let t = table.components(separatedBy: ".").last ?? table
        guard let db = db else { return }
        do {
            let cols = try await withReconnect(connection) { try await connection.listColumns(db: db, table: t) }
            await MainActor.run { self.columnCache[t] = cols }
        } catch {
            // 个别表加载失败不影响其它补全
        }
    }

    /// 自动补全用的「当前上下文表」：手动选择优先，否则用从 SQL 解析出的表。
    private var activeContextTable: String {
        contextTable.isEmpty ? detectedTable : contextTable
    }

    /// 从 SQL 文本解析出最近一次出现的表名（FROM / JOIN / UPDATE / INTO 之后）。
    private static func parseTable(from sql: String) -> String {
        let pattern = #"(?i)\b(?:from|join|update|into)\s+`?([a-zA-Z0-9_]+)`?(?:\.`?([a-zA-Z0-9_]+)`?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let ns = sql as NSString
        let matches = regex.matches(in: sql, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return "" }
        let g1 = last.range(at: 1).location != NSNotFound ? ns.substring(with: last.range(at: 1)) : ""
        let g2 = last.range(at: 2).location != NSNotFound ? ns.substring(with: last.range(at: 2)) : ""
        return g2.isEmpty ? g1 : g2
    }

    /// 根据当前输入的 SQL 重新解析上下文表，并在变化时自动加载其字段用于补全。
    @MainActor private func detectTableFromSQL() {
        let t = Self.parseTable(from: sql)
        if t != detectedTable {
            detectedTable = t
            Task { await loadContextColumnsAsync() }
        }
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
                }
                await MainActor.run { detectTableFromSQL() }
            }
        }
        .onChange(of: sql) { _ in detectTableFromSQL() }
        .alert("提示", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("确定") { editError = nil }
        } message: { Text(editError ?? "") }
    }

    private func loadTables(db: String) async {
        do {
            let list = try await withReconnect(connection) { try await connection.listTables(db: db) }.map { $0.name }
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
        let ct = activeContextTable
        guard let db = db, !ct.isEmpty else {
            await MainActor.run { self.contextColumns = [] }
            return
        }
        do {
            let cols = try await withReconnect(connection) { try await connection.listColumns(db: db, table: ct) }
            await MainActor.run {
                self.contextColumns = cols
                self.columnCache[ct] = cols
            }
        } catch {
            await MainActor.run { self.contextColumns = [] }
        }
    }

    /// 将候选词填入编辑器：
    /// - 限定符引用（a. / table.）：保留「限定符.」前缀，仅替换点后的部分；
    /// - 当前词为空（末尾/开头词边界）：末尾追加；
    /// - 否则：替换当前词。
    private func applySuggestion(_ suggestion: String) {
        let cw = currentWord
        if let dotRange = cw.lastIndex(of: ".") {
            let prefix = String(cw[...dotRange]) // 含最后的点
            sql = String(sql.dropLast(cw.count)) + prefix + suggestion + " "
            return
        }
        if cw.isEmpty {
            let needsSpace = !sql.isEmpty && !sql.hasSuffix(" ")
            sql = sql + (needsSpace ? " " : "") + suggestion + " "
            return
        }
        if let r = sql.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
            let before = String(sql[..<r.lowerBound])
            sql = before + " " + suggestion + " "
        } else {
            sql = suggestion + " "
        }
    }

    /// Insert a `SELECT * FROM <table>` template for the given (current) table.
    private func insertSelectAll(table: String) {
        sql = "SELECT * FROM `\(table)` "
    }

    /// 按分号切分多条语句，但忽略字符串字面量、反引号标识符与注释中的分号。
    /// 例：`SELECT * FROM t WHERE a='x;y'` 不会被误切成两条语句。
    private func splitStatements(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, inBacktick = false
        var inLineComment = false, inBlockComment = false
        let chars = Array(text)
        var i = 0
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inLineComment {
                current.append(c)
                if c == "\n" { inLineComment = false }
                i += 1; continue
            }
            if inBlockComment {
                current.append(c)
                if c == "*", next == "/" { current.append("/"); inBlockComment = false; i += 2; continue }
                i += 1; continue
            }
            if inSingle {
                current.append(c)
                if c == "\\", let n = next { current.append(n); i += 2; continue }
                if c == "'" {
                    if next == "'" { current.append("'"); i += 2; continue }
                    inSingle = false
                }
                i += 1; continue
            }
            if inDouble {
                current.append(c)
                if c == "\\", let n = next { current.append(n); i += 2; continue }
                if c == "\"" {
                    if next == "\"" { current.append("\""); i += 2; continue }
                    inDouble = false
                }
                i += 1; continue
            }
            if inBacktick {
                current.append(c)
                if c == "`" {
                    if next == "`" { current.append("`"); i += 2; continue }
                    inBacktick = false
                }
                i += 1; continue
            }
            // 普通状态：识别注释 / 引号起始
            if c == "-", next == "-", i + 2 < chars.count, chars[i + 2].isWhitespace {
                current.append("--"); current.append(chars[i + 2]); inLineComment = true; i += 3; continue
            }
            if c == "#" { current.append(c); inLineComment = true; i += 1; continue }
            if c == "/", next == "*" { current.append("/*"); inBlockComment = true; i += 2; continue }
            if c == "'" { current.append(c); inSingle = true; i += 1; continue }
            if c == "\"" { current.append(c); inDouble = true; i += 1; continue }
            if c == "`" { current.append(c); inBacktick = true; i += 1; continue }
            if c == ";" { flush(); i += 1; continue }
            current.append(c); i += 1
        }
        flush()
        return out
    }

    func run() async {
        // 收起键盘与状态写入都必须回到主线程（nonisolated async 函数默认在后台执行器运行）
        await MainActor.run {
            hideKeyboard()
            running = true
        }
        let stmts = splitStatements(sql)
        guard !stmts.isEmpty else {
            await MainActor.run { message = "请输入 SQL"; running = false }
            return
        }
        QueryHistory.add(sql)
        // 单条 SELECT 才尝试判定「可编辑」
        let single = stmts.count == 1 ? stmts[0] : nil
        do {
            var lastCols: [ColumnDef] = []
            var lastRows: [[String?]] = []
            var okCount = 0
            for s in stmts {
                let r = try await withReconnect(connection) { try await connection.query(s) }
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
        var failed = 0
        do {
            for ri in 0..<editingRows.count {
                guard ri < rows.count else { continue }
                let oldRow = rows[ri]
                let newRow = editingRows[ri]
                // 主键为 NULL 时无法定位行：跳过并计入失败，避免拼出 WHERE pk = '' 的「假成功」
                guard pkIndex < oldRow.count, let pkRaw = oldRow[pkIndex] else { failed += 1; continue }
                var sets: [String] = []
                for ci in 0..<editColumns.count {
                    let old = ci < oldRow.count ? oldRow[ci] : nil
                    let new = ci < newRow.count ? newRow[ci] : nil
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
                let pkVal = quoteVal(pkRaw)
                let sqlUpd = "UPDATE `\(editDB.replacingOccurrences(of: "`", with: "``"))`.`\(editTable.replacingOccurrences(of: "`", with: "``"))` SET \(sets.joined(separator: ", ")) WHERE `\(pk.replacingOccurrences(of: "`", with: "``"))` = \(pkVal) LIMIT 1"
                let r = try await withReconnect(connection) { try await connection.query(sqlUpd) }
                // 影响行数为 0 表示没有匹配到任何记录，不能报「保存成功」
                if case .ok(let n) = r, n == 0 { failed += 1 }
            }
            await MainActor.run {
                editMessage = failed == 0 ? "保存成功" : "保存完成（\(failed) 行未匹配到记录，未生效）"
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
            let cols = try await withReconnect(connection) { try await connection.listColumns(db: useDB, table: tableName) }
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
