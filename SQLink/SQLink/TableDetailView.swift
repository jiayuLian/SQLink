import SwiftUI

// MARK: - SQL WHERE / ORDER helpers
private func quoteLikeLiteral(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
}

private func quoteValue(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'") + "'"
}

/// 根据每个 FilterCondition 的 logic 字段拼接 WHERE。
/// 第一个条件无前导关系；后续条件用自身的 logic 与前一项连接，
/// 并用括号把每个条件包起来，避免 AND/OR 优先级歧义。
private func buildWhereClause(conditions: [FilterCondition]) -> String? {
    var parts: [String] = []
    for c in conditions where c.enabled && !c.field.isEmpty {
        let f = "`\(c.field.replacingOccurrences(of: "`", with: "``"))`"
        let sqlPart: String
        switch c.op {
        case .equal:         sqlPart = "\(f) = \(quoteValue(c.value))"
        case .notEqual:      sqlPart = "\(f) != \(quoteValue(c.value))"
        case .lessThan:      sqlPart = "\(f) < \(quoteValue(c.value))"
        case .lessOrEqual:   sqlPart = "\(f) <= \(quoteValue(c.value))"
        case .greaterThan:   sqlPart = "\(f) > \(quoteValue(c.value))"
        case .greaterOrEqual: sqlPart = "\(f) >= \(quoteValue(c.value))"
        case .contains:      sqlPart = "\(f) LIKE '%\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'"
        case .notContains:   sqlPart = "\(f) NOT LIKE '%\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'"
        case .startsWith:    sqlPart = "\(f) LIKE '\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'"
        case .notStartsWith: sqlPart = "\(f) NOT LIKE '\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'"
        case .endsWith:      sqlPart = "\(f) LIKE '%\(quoteLikeLiteral(c.value))' ESCAPE '\\\\'"
        case .notEndsWith:   sqlPart = "\(f) NOT LIKE '%\(quoteLikeLiteral(c.value))' ESCAPE '\\\\'"
        case .isNull:        sqlPart = "\(f) IS NULL"
        case .isNotNull:     sqlPart = "\(f) IS NOT NULL"
        case .isEmpty:       sqlPart = "\(f) = ''"
        case .isNotEmpty:    sqlPart = "\(f) != ''"
        case .inList:
            let vals = c.value.split(separator: ",").map { quoteValue(String($0).trimmingCharacters(in: .whitespaces)) }
            sqlPart = "\(f) IN (\(vals.joined(separator: ", ")))"
        case .notInList:
            let vals = c.value.split(separator: ",").map { quoteValue(String($0).trimmingCharacters(in: .whitespaces)) }
            sqlPart = "\(f) NOT IN (\(vals.joined(separator: ", ")))"
        case .custom:
            sqlPart = c.value
        }
        if sqlPart.isEmpty { continue }
        if parts.isEmpty {
            parts.append("(\(sqlPart))")
        } else {
            let logic = c.logic?.rawValue ?? "AND"
            parts.append("\(logic) (\(sqlPart))")
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

private func buildOrderBy(field: String, direction: SortDirection) -> String? {
    field.isEmpty ? nil : "`\(field.replacingOccurrences(of: "`", with: "``"))` \(direction.rawValue.uppercased())"
}

// MARK: - DDL 美化与高亮
private let sqlKeywordSet: Set<String> = [
    "CREATE","TABLE","TEMPORARY","PRIMARY","KEY","NOT","NULL","DEFAULT","UNIQUE",
    "AUTO_INCREMENT","ENGINE","CHARSET","COLLATE","CONSTRAINT","FOREIGN","REFERENCES",
    "INDEX","UNSIGNED","ZEROFILL","ON","DELETE","UPDATE","CASCADE","COMMENT","IF",
    "EXISTS","ALGORITHM","LOCK","FULLTEXT","SPATIAL","VIEW","AS","SELECT","FROM",
    "WHERE","AND","OR","ORDER","BY","LIMIT","INNER","LEFT","RIGHT","OUTER","JOIN",
    "SET","VALUES","INSERT","INTO","REPLACE","DROP","ALTER","ADD","MODIFY","CHANGE",
    "DESC","ASC","DISTINCT","GROUP","HAVING","LIKE","IN","IS","BETWEEN"
]

/// 把 SHOW CREATE TABLE 的整段语句整理成带缩进的多行文本（只增删空白，不改变 SQL 语义）。
private func formatCreateTable(_ raw: String) -> String {
    let compact = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces)
    guard !compact.isEmpty else { return raw }
    var out = ""
    var depth = 0
    var it = compact.startIndex
    while it < compact.endIndex {
        let c = compact[it]
        if c == "(" {
            out.append("(")
            depth += 1
            if depth == 1 { out.append("\n  ") }
            it = compact.index(after: it)
        } else if c == ")" {
            depth -= 1
            if depth <= 0 { out.append("\n)") } else { out.append(")") }
            if depth < 0 { depth = 0 }
            it = compact.index(after: it)
        } else if c == "," {
            if depth == 1 { out.append(",\n  ") } else { out.append(",") }
            it = compact.index(after: it)
        } else {
            out.append(String(c))
            it = compact.index(after: it)
        }
    }
    let opts: [(String, String)] = [
        ("ENGINE", "\\w+"),
        ("DEFAULT CHARSET", "\\w+"),
        ("COLLATE", "\\w+"),
        ("AUTO_INCREMENT", "\\d+"),
        ("ROW_FORMAT", "\\w+"),
        ("COMMENT", "'[^']*'")
    ]
    for (kw, valPat) in opts {
        let pat = "(\\s+)\(kw)(\\s*=\\s*\(valPat))"
        if let re = try? NSRegularExpression(pattern: pat) {
            out = re.stringByReplacingMatches(in: out,
                                               range: NSRange(out.startIndex..., in: out),
                                               withTemplate: "\n\(kw)$2")
        }
    }
    return out
}

/// 简易 SQL 语法高亮：关键字 / 反引号标识符 / 字符串 / 数字 分别着色，类似数据库客户端。
private func highlightSQL(_ source: String) -> AttributedString {
    var result = AttributedString()
    let pattern = "(--[^\\n]*|#[^\\n]*|/\\*.*?\\*/|'[^']*'|`[^`]*`|\\d+(?:\\.\\d+)?|[A-Za-z_][A-Za-z0-9_]*|\\s+|[(),;.]|[^\\s])"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return AttributedString(source)
    }
    let ns = source as NSString
    let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
    let kwColor = Color.accentColor
    let idColor = Color(red: 0.16, green: 0.55, blue: 0.38)
    let strColor = Color(red: 0.78, green: 0.42, blue: 0.12)
    let numColor = Color(red: 0.50, green: 0.28, blue: 0.70)
    for m in matches {
        guard let range = Range(m.range, in: source) else { continue }
        let token = String(source[range])
        var attr = AttributedString(token)
        if token.hasPrefix("`") {
            attr.foregroundColor = idColor
        } else if token.hasPrefix("'") {
            attr.foregroundColor = strColor
        } else if token.hasPrefix("--") || token.hasPrefix("#") || token.hasPrefix("/*") {
            attr.foregroundColor = Color.gray
        } else if let _ = Double(token), token.rangeOfCharacter(from: .decimalDigits) != nil {
            attr.foregroundColor = numColor
        } else if sqlKeywordSet.contains(token.uppercased()) {
            attr.foregroundColor = kwColor
        }
        result += attr
    }
    return result
}

// MARK: - Table detail
struct TableDetailView: View {
    let connection: MySQLConnection
    let db: String
    let table: String

    @State private var columns: [ColumnInfo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var rowCount: Int? = nil

    // 建表 SQL 弹窗
    @State private var showDDL = false
    @State private var ddlText: String = ""
    @State private var ddlLoading = false
    @State private var ddlError: String?
    @State private var ddlScale: CGFloat = 1.0

    // filter & sort (lifted here so they persist across sheet / navigation)
    @State private var showFilter = false
    @State private var filterConditions: [FilterCondition] = []
    @State private var sortField: String = ""
    @State private var sortDirection: SortDirection = .asc
    @State private var filterLogic: FilterLogic = .and
    @State private var activeWhere: String? = nil
    @State private var activeOrderBy: String? = nil

    var body: some View {
        List {
            Section("结构（\(columns.count) 列）") {
                if columns.isEmpty {
                    Text("加载中…").foregroundColor(.secondary)
                }
                ForEach(columns) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.field).font(.system(size: 14, weight: .bold))
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
                        if !c.comment.isEmpty {
                            Text("备注：\(c.comment)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Button { showDDL = true } label: {
                    Label("查看建表 SQL", systemImage: "doc.plaintext")
                }
            }

            Section {
                if activeWhere != nil || activeOrderBy != nil {
                    HStack {
                        Text(filterStatusSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }

            Section {
                NavigationLink {
                    TableDataView(connection: connection, db: db, table: table,
                                  conditions: $filterConditions,
                                  sortField: $sortField,
                                  sortDirection: $sortDirection,
                                  filterLogic: $filterLogic,
                                  activeWhere: $activeWhere,
                                  activeOrderBy: $activeOrderBy)
                } label: {
                    HStack {
                        Label("查看数据", systemImage: "tablecells")
                        Spacer()
                        if let n = rowCount {
                            Text("匹配 \(n) 条").font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("加载中…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink("打开查询控制台", destination: QueryConsoleView(connection: connection, db: db, defaultTable: table))
            }
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if showFilter { filterOverlay }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showFilter = true } label: {
                    Label("筛选&排序", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: activeWhere) { _ in
            Task { await load() }
        }
        .onChange(of: activeOrderBy) { _ in
            Task { await load() }
        }
        .task { await load() }
        .sheet(isPresented: $showDDL) {
            NavigationView {
                Group {
                    if ddlLoading {
                        ProgressView("加载中…")
                    } else if let err = ddlError {
                        ScrollView { Text(err).foregroundColor(.red).padding() }
                    } else {
                        ScrollView {
                            Text(ddlDisplay)
                                .font(.system(.body, design: .monospaced))
                                .scaleEffect(ddlScale)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                                .padding(8)
                                .contentShape(Rectangle())
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { v in ddlScale = min(max(v, 0.6), 4.0) }
                                )
                        }
                    }
                }
                .navigationTitle("建表 SQL")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("1:1") { ddlScale = 1.0 }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = ddlText.isEmpty ? "" : formatCreateTable(ddlText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showDDL = false }
                    }
                }
            }
            .task { await loadDDL() }
        }
    }

    private func loadDDL() async {
        ddlLoading = true; ddlError = nil; ddlText = ""
        do {
            let sql = try await connection.showCreateTable(db: db, table: table)
            await MainActor.run {
                self.ddlText = sql
                self.ddlLoading = false
            }
        } catch {
            await MainActor.run {
                self.ddlError = error.localizedDescription
                self.ddlLoading = false
            }
        }
    }

    /// DDL 展示文本：整理缩进 + 语法高亮；空时给占位提示。
    private var ddlDisplay: AttributedString {
        if ddlText.isEmpty { return AttributedString("（无建表语句）") }
        return highlightSQL(formatCreateTable(ddlText))
    }

    private var filterStatusSummary: String {
        var parts: [String] = []
        if activeWhere != nil {
            let n = filterConditions.filter { $0.enabled && !$0.field.isEmpty }.count
            if n > 0 { parts.append("\(n) 个筛选") }
        }
        if activeOrderBy != nil && !sortField.isEmpty {
            parts.append("排序：\(sortField) \(sortDirection.label)")
        }
        return parts.joined(separator: "，")
    }

    /// 自定义筛选弹窗 overlay（表详情页用），与 TableDataView 保持一致，避免 sheet dismiss 残留遮罩。
    private var filterOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showFilter = false }
            VStack(spacing: 0) {
                TableFilterView(columns: columns,
                                conditions: $filterConditions,
                                sortField: $sortField,
                                sortDirection: $sortDirection,
                                filterLogic: $filterLogic,
                                isPresented: $showFilter,
                                db: db,
                                table: table,
                                connection: connection,
                                onApply: { w, o in
                                    activeWhere = w; activeOrderBy = o
                                })
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
            .shadow(radius: 10)
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            async let cols = connection.listColumns(db: db, table: table)
            async let cnt = connection.countRows(db: db, table: table, whereClause: activeWhere)
            let c = try await cols
            let n = try await cnt
            await MainActor.run {
                self.columns = c
                self.rowCount = n
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }
}

// MARK: - Filter / sort sheet
struct TableFilterView: View {
    let columns: [ColumnInfo]
    @Binding var conditions: [FilterCondition]
    @Binding var sortField: String
    @Binding var sortDirection: SortDirection
    @Binding var filterLogic: FilterLogic
    /// 显式绑定 sheet 的显示状态，避免 `dismiss()` 反向同步失败导致按钮被阻塞。
    @Binding var isPresented: Bool

    let db: String
    let table: String
    let connection: MySQLConnection
    let onApply: (String?, String?) -> Void

    private var fieldNames: [String] { columns.map { $0.field } }

    // Local drafts so changes inside the sheet are not committed until the user taps 应用.
    // This also prevents any state reset on sheet re-open.
    @State private var draftConditions: [FilterCondition] = []
    @State private var draftSortField: String = ""
    @State private var draftSortDirection: SortDirection = .asc
    @State private var draftFilterLogic: FilterLogic = .and
    // 建议值自动加载已临时移除：原方案在弹窗关闭后异步任务会写回已释放的 @State 导致闪退。

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("取消") { DispatchQueue.main.async { isPresented = false } }
                Spacer()
                Text("筛选 & 排序").font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    Button("清除") {
                        draftConditions = []
                        draftSortField = ""; draftSortDirection = .asc
                        draftFilterLogic = .and
                    }
                    Button("应用") {
                        conditions = draftConditions
                        sortField = draftSortField
                        sortDirection = draftSortDirection
                        filterLogic = draftFilterLogic
                        let whereClause = buildWhereClause(conditions: conditions)
                        let orderBy = buildOrderBy(field: sortField, direction: sortDirection)
                        onApply(whereClause, orderBy)
                        // 延迟到下一轮 runloop 再关闭 sheet：
                        // 先让本次点击产生的多处 @Binding 变更落定，避免「变更 + 关闭」同帧竞争
                        // 导致 sheet 未真正销毁、留下透明遮罩吞掉下层按钮的点击。
                        DispatchQueue.main.async { isPresented = false }
                    }
                    .font(Font.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            Divider()
            Form {
                Section {
                    Button { addCondition() } label: { Label("添加筛选条件", systemImage: "plus") }
                }

                ForEach($draftConditions) { $c in
                    let cid = $c.wrappedValue.id
                    Section {
                        FilterConditionRow(condition: $c,
                                           showLogic: $c.wrappedValue.logic != nil,
                                           fields: fieldNames,
                                           suggestions: [],
                                           loading: false,
                                           onDelete: { removeCondition(id: cid) })
                    }
                }

                Section("排序") {
                    Picker("排序字段", selection: $draftSortField) {
                        Text("无").tag("")
                        ForEach(fieldNames, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)   // 使用菜单避免 push 导航页，防止 overlay 弹窗被意外关闭
                    Picker("方向", selection: $draftSortDirection) {
                        ForEach(SortDirection.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            draftConditions = conditions
            draftSortField = sortField
            draftSortDirection = sortDirection
            draftFilterLogic = filterLogic
            if !draftSortField.isEmpty && !fieldNames.contains(draftSortField) { draftSortField = "" }
        }
    }

    private func addCondition() {
        let field = fieldNames.first ?? ""
        let logic: FilterLogic? = draftConditions.isEmpty ? nil : .and
        draftConditions.append(FilterCondition(field: field, op: .contains, value: "", enabled: true, logic: logic))
    }

    private func removeCondition(id: UUID) {
        draftConditions.removeAll { $0.id == id }
        // 删除后剩余条件的首条不应再显示 AND/OR 关系（它前面没有其它条件）。
        if !draftConditions.isEmpty {
            draftConditions[0].logic = nil
        }
    }

    // 建议值加载功能已临时移除（见上方说明），回归稳定优先。

}

// MARK: - Filter condition row
/// 条件行纯粹由绑定驱动，自身不持有 @State、不跑异步任务，
/// 因此弹窗关闭/行销毁时不存在任何后台任务去写已释放的视图存储。
struct FilterConditionRow: View {
    @Binding var condition: FilterCondition
    let showLogic: Bool
    let fields: [String]
    let suggestions: [String]
    let loading: Bool
    var onDelete: () -> Void

    private var logicBinding: Binding<FilterLogic> {
        Binding<FilterLogic>(
            get: { condition.logic ?? .and },
            set: { condition.logic = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $condition.enabled)
                    .labelsHidden()
                if showLogic {
                    Picker("关系", selection: logicBinding) {
                        ForEach(FilterLogic.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                Picker("字段", selection: $condition.field) {
                    ForEach(fields, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
            }

            Picker("运算符", selection: $condition.op) {
                ForEach(FilterOperator.allCases) { op in
                    Text(op.label).tag(op)
                }
            }
            .pickerStyle(.menu)

            if condition.op.needsValue {
                TextField("值", text: $condition.value)
                    .textInputAutocapitalization(.never)
            }

            if !suggestions.isEmpty || loading {
                SuggestionChips(values: suggestions, loading: loading) { v in
                    condition.value = v
                }
            }
        }
    }
}

// MARK: - Suggestion chips
struct SuggestionChips: View {
    let values: [String]
    let loading: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("建议值").font(.caption).foregroundColor(.secondary)
            if loading {
                ProgressView().scaleEffect(0.8)
            } else if values.isEmpty {
                Text("无").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(values.prefix(20), id: \.self) { v in
                            Button { onSelect(v) } label: {
                                Text(v).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dedicated data view (big, scrollable, editable)
/// Opened from TableDetailView via NavigationLink. Owns its own data load + edit,
/// while the filter/sort state is shared through bindings so it persists across
/// sheet open/close and navigation push/pop.
struct TableDataView: View {
    let connection: MySQLConnection
    let db: String
    let table: String

    @Binding var conditions: [FilterCondition]
    @Binding var sortField: String
    @Binding var sortDirection: SortDirection
    @Binding var filterLogic: FilterLogic
    @Binding var activeWhere: String?
    @Binding var activeOrderBy: String?

    @EnvironmentObject var settings: AppSettings

    @State private var columns: [ColumnInfo] = []
    @State private var previewCols: [ColumnDef] = []
    @State private var previewRows: [[String?]] = []
    @State private var rowCount: Int? = nil
    @State private var rawCount: Int = 0
    @State private var loading = true
    @State private var error: String?
    @State private var page = 1
    @State private var exportError: String?

    // 导出进度（引用类型，便于后台 Task 安全更新 UI）
    @StateObject private var exportState = ExportProgressModel()

    @State private var showFilter = false

    // 数据表格双指缩放（0.6~3.0）；gridMagnify 为手势进行中的临时比例
    @State private var gridScale: CGFloat = 1.0
    @GestureState private var gridMagnify: CGFloat = 1.0

    // export
    // （导出分享面板改为直接 present，不再用 @State + .sheet，避免首次弹出空白）

    // inline edit
    @State private var editMode = false
    @State private var editingValues: [[String?]] = []
    @State private var hasChanges = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    private var primaryKey: String? {
        columns.first { $0.key == "PRI" }?.field ?? columns.first { $0.key == "UNI" }?.field
    }

    /// 是否已应用筛选或排序条件（带 WHERE 或 ORDER BY）。整表裸查为 false，不显示编辑按钮。
    private var hasFilterCondition: Bool {
        !(activeWhere?.isEmpty ?? true) || !(activeOrderBy?.isEmpty ?? true)
    }

    var body: some View {
        mainContent
            .navigationTitle(table)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dataToolbar }
            .onChange(of: activeWhere) { _ in page = 1; Task { await load() } }
            .onChange(of: activeOrderBy) { _ in page = 1; Task { await load() } }
            .onChange(of: page) { _ in
                Task { await load() }
            }
            .onChange(of: settings.pageSize) { _ in Task { await load() } }
            .task { await load() }
    }

    private var mainContent: some View {
        Group {
            if loading {
                ProgressView("加载中…")
            } else if let error = error {
                ScrollView { Text(error).foregroundColor(.red).padding() }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        if let n = rowCount {
                            Text("共 \(n) 条 · 第 \(page)/\(maxPage) 页")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if editMode && primaryKey == nil {
                            Text("⚠ 无主键/唯一键，不可保存").font(.caption2).foregroundColor(.orange).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.06))

                    // 免费版浏览上限提示
                    if isViewLimited {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill").font(.caption2)
                            Text("免费版最多查看 \(settings.plan.freeViewLimit) 条，共 \(rawCount) 条已隐藏，升级会员查看全部")
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                    }

                    if editMode {
                        EditableGridView(columns: columns, rows: $editingValues,
                                         originalRows: previewRows, primaryKey: primaryKey,
                                         scale: gridScale * gridMagnify,
                                         onChange: { hasChanges = true })
                            .frame(maxHeight: .infinity)
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
                        ResultGridView(columns: previewCols, rows: previewRows, primaryKey: primaryKey, scale: gridScale * gridMagnify)
                            .frame(maxHeight: .infinity)
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

                    if let saveMessage = saveMessage {
                        Text(saveMessage).font(.footnote).foregroundColor(.green)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                    }
                    if let saveError = saveError {
                        Text(saveError).font(.footnote).foregroundColor(.red)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                    }

                    // 分页控件
                    Divider()
                    HStack(spacing: 12) {
                        Button { if page > 1 { page -= 1 } } label: { Label("上一页", systemImage: "chevron.left") }
                            .disabled(page <= 1 || loading)
                        Text("\(page) / \(maxPage)").font(.caption)
                        Button { if page < maxPage { page += 1 } } label: { Label("下一页", systemImage: "chevron.right") }
                            .disabled(page >= maxPage || loading)
                        Spacer()
                        Menu { ForEach([50, 100, 200, 500], id: \.self) { s in
                            Button("\(s) 条/页") { settings.pageSize = s; page = 1 }
                        } } label: {
                            Label("\(settings.pageSize) 条/页", systemImage: "line.3.horizontal")
                                .font(.caption)
                        }
                        if gridScale != 1 {
                            Button { gridScale = 1 } label: {
                                Label("\(Int(gridScale * 100))%", systemImage: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.gray.opacity(0.04))
                }
                // 导出进度遮罩 与 筛选弹窗（用 overlay 替代 sheet，避免 iOS sheet dismiss 后留下透明遮罩吞掉 body 点击）
                .overlay {
                    if exportState.isExporting { exportOverlay }
                    if showFilter { filterOverlay }
                }
            }
        }
    }

    /// 自定义筛选弹窗 overlay：背景遮罩 + 卡片式弹窗，不依赖 .sheet 的 presentationController。
    private var filterOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showFilter = false }
            VStack(spacing: 0) {
                TableFilterView(columns: columns,
                                conditions: $conditions,
                                sortField: $sortField,
                                sortDirection: $sortDirection,
                                filterLogic: $filterLogic,
                                isPresented: $showFilter,
                                db: db, table: table, connection: connection,
                                onApply: { w, o in
                                    activeWhere = w; activeOrderBy = o
                                })
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
            .shadow(radius: 10)
        }
    }

    private var maxPage: Int {
        let ps = max(1, settings.pageSize)
        return max(1, Int(ceil(Double(rowCount ?? 0) / Double(ps))))
    }
    private var isViewLimited: Bool {
        !settings.isPro && rawCount > settings.plan.freeViewLimit
    }
    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: exportState.progress) { Text("导出中…").foregroundColor(.white) }
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    .frame(width: 200)
                if let m = exportState.message { Text(m).font(.caption).foregroundColor(.white) }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        }
    }

    @ToolbarContentBuilder
    private var dataToolbar: some ToolbarContent {
        // 把操作按钮放到工具栏（与「导出」同一交互层）。
        // body 区域此前会被一层看不见的遮罩/手势层覆盖，导致筛选&排序/编辑失灵，
        // 而工具栏在独立的 navigationBar 层、始终可点（用户实测「导出」一直能用即证明）。
        // 因此将所有操作入口上移到工具栏，从根本规避 body 点击被吞的问题。
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showFilter = true } label: {
                Label("筛选&排序", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if editMode {
                Button("取消") { cancelEdit() }
            } else if settings.isPro && hasFilterCondition {
                Button { enterEdit() } label: { Label("编辑", systemImage: "square.and.pencil") }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if editMode {
                Button { Task { await saveEdits() } } label: { Label("保存", systemImage: "checkmark") }
                    .disabled(primaryKey == nil || !hasChanges)
            } else {
                Menu {
                    Button { exportAs(.csv) } label: { Label("导出 CSV", systemImage: "doc") }
                    Button { exportAs(.sql) } label: { Label("导出 SQL", systemImage: "swiftdata") }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
            }
        }
    }

    /// 连接断开（写入数据失败 / 被服务器关闭）时自动重连一次再重试，避免「点击查看数据却报写入失败」。
    private func withReconnect<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as MySQLError where e.isDeadConnection {
            try await connection.reconnect()
            return try await body()
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            try await fetchData()
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        await MainActor.run { loading = false }
    }

    private func fetchData() async throws {
        let pageSize = max(1, settings.pageSize)
        // 先取真实总数，用于免费版浏览上限判断
        let raw = try await withReconnect { try await connection.countRows(db: db, table: table, whereClause: activeWhere) }
        let viewLimit = settings.isPro ? Int.max : settings.plan.freeViewLimit
        let displayTotal = min(raw, viewLimit)
        let computedMaxPage = max(1, Int(ceil(Double(displayTotal) / Double(pageSize))))
        let safePage = min(max(1, page), computedMaxPage)
        if safePage != page { await MainActor.run { page = safePage } }
        let offset = (safePage - 1) * pageSize

        async let cols = withReconnect { try await connection.listColumns(db: db, table: table) }
        let c = try await cols
        async let prev = withReconnect { try await connection.fetchRows(db: db, table: table, limit: pageSize, offset: offset,
                                                 whereClause: activeWhere, orderBy: activeOrderBy) }
        let p = try await prev
        var pc = [ColumnDef](); var pr = [[String?]]()
        if case .result(let cc, let rr) = p { pc = cc; pr = rr }
        await MainActor.run {
            self.columns = c
            self.previewCols = pc
            self.previewRows = pr
            self.rawCount = raw
            self.rowCount = displayTotal
        }
    }

    private func exportAs(_ format: ExportFormat) {
        guard !exportState.isExporting else { return }
        // 免费版限制导出行数；会员无限制。
        let maxRows = settings.isPro ? nil : settings.plan.freeExportLimit
        exportState.isExporting = true
        exportState.progress = 0
        exportState.message = "准备中…"
        Task.detached(priority: .userInitiated) { [connection, db, table, activeWhere, activeOrderBy, state = exportState] in
            do {
                let url = try await ExportUtils.exportTableStreaming(
                    connection: connection, db: db, table: table,
                    whereClause: activeWhere, orderBy: activeOrderBy,
                    format: format, maxRows: maxRows, chunkSize: 500
                ) { progress, count in
                    Task { @MainActor in
                        state.progress = progress
                        state.message = "已导出 \(count) 行"
                    }
                }
                await MainActor.run {
                    state.isExporting = false
                    ExportUtils.shareFile(url)
                }
            } catch {
                await MainActor.run {
                    state.isExporting = false
                    state.message = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func enterEdit() {
        editingValues = previewRows.map { $0.map { $0 } }
        hasChanges = false
        saveMessage = nil; saveError = nil
        editMode = true
    }

    private func cancelEdit() {
        editMode = false
        editingValues = []
        hasChanges = false
        saveMessage = nil; saveError = nil
    }

    private func saveEdits() async {
        guard let pk = primaryKey else {
            await MainActor.run { saveError = "未检测到主键或唯一键" }
            return
        }
        guard let pkIndex = columns.firstIndex(where: { $0.field == pk }) else {
            await MainActor.run { saveError = "主键列索引异常" }
            return
        }
        do {
            for ri in 0..<editingValues.count {
                var sets: [String] = []
                for ci in 0..<columns.count {
                    let old = previewRows[ri][ci]
                    let new = editingValues[ri][ci]
                    if old != new {
                        let col = "`\(columns[ci].field.replacingOccurrences(of: "`", with: "``"))`"
                        if let v = new {
                            sets.append("\(col) = \(quoteValue(v))")
                        } else {
                            sets.append("\(col) = NULL")
                        }
                    }
                }
                guard !sets.isEmpty else { continue }
                let pkVal = quoteValue(previewRows[ri][pkIndex] ?? "")
                let sql = "UPDATE `\(db.replacingOccurrences(of: "`", with: "``"))`.`\(table.replacingOccurrences(of: "`", with: "``"))` SET \(sets.joined(separator: ", ")) WHERE `\(pk.replacingOccurrences(of: "`", with: "``"))` = \(pkVal) LIMIT 1"
                _ = try await withReconnect { try await connection.query(sql) }
            }
            await MainActor.run {
                saveMessage = "保存成功"
                saveError = nil
                editMode = false
            }
            await load()
        } catch {
            await MainActor.run { saveError = "保存失败：\(error.localizedDescription)" }
        }
    }
}
