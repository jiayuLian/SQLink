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
                Button { Task { await loadDDL() } } label: {
                    Label("查看建表 SQL", systemImage: "doc.plaintext")
                }
            }

            Section {
                HStack {
                    Button { showFilter = true } label: {
                        Label("筛选 & 排序", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Spacer()
                    if activeWhere != nil || activeOrderBy != nil {
                        Text(filterStatusSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
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
        .sheet(isPresented: $showFilter) {
            TableFilterView(columns: columns,
                            conditions: $filterConditions,
                            sortField: $sortField,
                            sortDirection: $sortDirection,
                            filterLogic: $filterLogic,
                            db: db,
                            table: table,
                            connection: connection,
                            onApply: { w, o in
                                activeWhere = w; activeOrderBy = o
                            })
        }
        .onChange(of: activeWhere) { _ in Task { await load() } }
        .onChange(of: activeOrderBy) { _ in Task { await load() } }
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
                            Text(ddlText.isEmpty ? "（无建表语句）" : ddlText)
                                .font(.system(.body, design: .monospaced))
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("建表 SQL")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showDDL = false }
                    }
                }
            }
        }
    }

    private func loadDDL() async {
        ddlLoading = true; ddlError = nil; ddlText = ""
        do {
            let sql = try await connection.showCreateTable(db: db, table: table)
            await MainActor.run {
                self.ddlText = sql
                self.ddlLoading = false
                self.showDDL = true
            }
        } catch {
            await MainActor.run {
                self.ddlError = error.localizedDescription
                self.ddlLoading = false
                self.showDDL = true
            }
        }
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
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button { addCondition() } label: { Label("添加筛选条件", systemImage: "plus") }
                }

                ForEach(0..<draftConditions.count, id: \.self) { index in
                    Section {
                        FilterConditionRow(condition: $draftConditions[index],
                                           index: index,
                                           fields: fieldNames,
                                           db: db, table: table, connection: connection,
                                           onDelete: { removeCondition(at: index) })
                    }
                }

                Section("排序") {
                    Picker("排序字段", selection: $draftSortField) {
                        Text("无").tag("")
                        ForEach(fieldNames, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("方向", selection: $draftSortDirection) {
                        ForEach(SortDirection.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("筛选 & 排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清除") {
                        draftConditions = []
                        draftSortField = ""; draftSortDirection = .asc
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("应用") {
                        conditions = draftConditions
                        sortField = draftSortField
                        sortDirection = draftSortDirection
                        let whereClause = buildWhereClause(conditions: conditions)
                        let orderBy = buildOrderBy(field: sortField, direction: sortDirection)
                        onApply(whereClause, orderBy)
                        dismiss()
                    }
                }
            }
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

    private func removeCondition(at index: Int) {
        draftConditions.remove(at: index)
    }
}

// MARK: - Filter condition row
/// Each row owns its own suggestion state to avoid cross-row binding coupling
/// (the previous shared `activeField`/`suggestions` design could crash on add).
struct FilterConditionRow: View {
    @Binding var condition: FilterCondition
    let index: Int
    let fields: [String]
    let db: String
    let table: String
    let connection: MySQLConnection
    var onDelete: () -> Void

    @State private var suggestions: [String] = []
    @State private var loadingSuggestions = false

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
                if index > 0 {
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

            if !suggestions.isEmpty || loadingSuggestions {
                SuggestionChips(values: suggestions, loading: loadingSuggestions) { v in
                    condition.value = v
                }
            }
        }
        .onAppear { loadSuggestions(for: condition.field) }
        .onChange(of: condition.field) { loadSuggestions(for: $0) }
    }

    private func loadSuggestions(for field: String) {
        guard !field.isEmpty else { suggestions = []; loadingSuggestions = false; return }
        loadingSuggestions = true; suggestions = []
        Task {
            do {
                let vals = try await connection.distinctValues(db: db, table: table, column: field, limit: 100)
                await MainActor.run {
                    suggestions = vals
                    loadingSuggestions = false
                }
            } catch {
                await MainActor.run { loadingSuggestions = false }
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

    /// 是否已应用筛选条件（带 WHERE）。整表裸查为 false，不显示编辑按钮。
    private var hasFilterCondition: Bool {
        !(activeWhere?.isEmpty ?? true)
    }

    var body: some View {
        mainContent
            .navigationTitle(table)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dataToolbar }
            .sheet(isPresented: $showFilter) {
                TableFilterView(columns: columns,
                                conditions: $conditions,
                                sortField: $sortField,
                                sortDirection: $sortDirection,
                                filterLogic: $filterLogic,
                                db: db, table: table, connection: connection,
                                onApply: { w, o in
                                    activeWhere = w; activeOrderBy = o
                                })
            }
            .onChange(of: activeWhere) { _ in page = 1; Task { await load() } }
            .onChange(of: activeOrderBy) { _ in page = 1; Task { await load() } }
            .onChange(of: page) { _ in Task { await load() } }
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
                        if editMode {
                            Button("取消") { cancelEdit() }.font(.caption)
                            Button { Task { await saveEdits() } } label: { Label("保存", systemImage: "checkmark") }
                                .disabled(primaryKey == nil || !hasChanges)
                        } else if settings.isPro && hasFilterCondition {
                            Button { enterEdit() } label: { Label("编辑", systemImage: "square.and.pencil") }
                            if primaryKey == nil {
                                Text("⚠ 无主键/唯一键，不可保存").font(.caption2).foregroundColor(.orange).lineLimit(1)
                            }
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
                                         originalRows: previewRows, scale: gridScale * gridMagnify,
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
                        ResultGridView(columns: previewCols, rows: previewRows, scale: gridScale * gridMagnify)
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
                // 导出进度遮罩
                .overlay { if exportState.isExporting { exportOverlay } }
            }
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
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showFilter = true } label: { Label("筛选", systemImage: "line.3.horizontal.decrease.circle") }
        }
        // 导出：所有用户可用；免费版按免费额度限制行数，会员无限制。
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { exportAs(.csv) } label: { Label("导出 CSV", systemImage: "doc") }
                Button { exportAs(.sql) } label: { Label("导出 SQL", systemImage: "swiftdata") }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
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
        async let prev = withReconnect { try await connection.fetchRows(db: db, table: table, limit: pageSize, offset: offset,
                                                 whereClause: activeWhere, orderBy: activeOrderBy) }
        let c = try await cols
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
