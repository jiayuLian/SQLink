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

private func buildWhereClause(conditions: [FilterCondition], logic: String = "AND") -> String? {
    var parts: [String] = []
    for c in conditions where c.enabled && !c.field.isEmpty {
        let f = "`\(c.field.replacingOccurrences(of: "`", with: "``"))`"
        switch c.op {
        case .equal:         parts.append("\(f) = \(quoteValue(c.value))")
        case .notEqual:      parts.append("\(f) != \(quoteValue(c.value))")
        case .lessThan:      parts.append("\(f) < \(quoteValue(c.value))")
        case .lessOrEqual:   parts.append("\(f) <= \(quoteValue(c.value))")
        case .greaterThan:   parts.append("\(f) > \(quoteValue(c.value))")
        case .greaterOrEqual: parts.append("\(f) >= \(quoteValue(c.value))")
        case .contains:      parts.append("\(f) LIKE '%\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'")
        case .notContains:   parts.append("\(f) NOT LIKE '%\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'")
        case .startsWith:    parts.append("\(f) LIKE '\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'")
        case .notStartsWith: parts.append("\(f) NOT LIKE '\(quoteLikeLiteral(c.value))%' ESCAPE '\\\\'")
        case .endsWith:      parts.append("\(f) LIKE '%\(quoteLikeLiteral(c.value))' ESCAPE '\\\\'")
        case .notEndsWith:   parts.append("\(f) NOT LIKE '%\(quoteLikeLiteral(c.value))' ESCAPE '\\\\'")
        case .isNull:        parts.append("\(f) IS NULL")
        case .isNotNull:     parts.append("\(f) IS NOT NULL")
        case .isEmpty:       parts.append("\(f) = ''")
        case .isNotEmpty:    parts.append("\(f) != ''")
        case .inList:
            let vals = c.value.split(separator: ",").map { quoteValue(String($0).trimmingCharacters(in: .whitespaces)) }
            parts.append("\(f) IN (\(vals.joined(separator: ", ")))")
        case .notInList:
            let vals = c.value.split(separator: ",").map { quoteValue(String($0).trimmingCharacters(in: .whitespaces)) }
            parts.append("\(f) NOT IN (\(vals.joined(separator: ", ")))")
        case .custom:
            if !c.value.isEmpty { parts.append(c.value) }
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " \(logic) ")
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
                    }
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

                Section {
                    Picker("多个条件之间的关系", selection: $draftFilterLogic) {
                        ForEach(FilterLogic.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("条件关系")
                }

                ForEach($draftConditions) { $condition in
                    Section {
                        FilterConditionRow(condition: $condition,
                                           fields: fieldNames,
                                           db: db, table: table, connection: connection,
                                           onDelete: { removeCondition(id: condition.id) })
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
                        filterLogic = draftFilterLogic
                        let whereClause = buildWhereClause(conditions: conditions, logic: filterLogic.rawValue)
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
        draftConditions.append(FilterCondition(field: field, op: .contains, value: "", enabled: true))
    }

    private func removeCondition(id: UUID) {
        draftConditions.removeAll { $0.id == id }
    }
}

// MARK: - Filter condition row
/// Each row owns its own suggestion state to avoid cross-row binding coupling
/// (the previous shared `activeField`/`suggestions` design could crash on add).
struct FilterConditionRow: View {
    @Binding var condition: FilterCondition
    let fields: [String]
    let db: String
    let table: String
    let connection: MySQLConnection
    var onDelete: () -> Void

    @State private var suggestions: [String] = []
    @State private var loadingSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $condition.enabled)
                    .labelsHidden()
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

    @State private var columns: [ColumnInfo] = []
    @State private var previewCols: [ColumnDef] = []
    @State private var previewRows: [[String?]] = []
    @State private var rowCount: Int? = nil
    @State private var loading = true
    @State private var error: String?

    @State private var showFilter = false

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
            .onChange(of: activeWhere) { _ in Task { await load() } }
            .onChange(of: activeOrderBy) { _ in Task { await load() } }
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
                            Text("匹配 \(n) 条，已显示前 \(previewRows.count) 条")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if editMode {
                            Button("取消") { cancelEdit() }.font(.caption)
                            Button { Task { await saveEdits() } } label: { Label("保存", systemImage: "checkmark") }
                                .disabled(primaryKey == nil || !hasChanges)
                        } else {
                            Button { enterEdit() } label: { Label("编辑", systemImage: "square.and.pencil") }
                            if primaryKey == nil {
                                Text("⚠ 无主键/唯一键，不可保存").font(.caption2).foregroundColor(.orange).lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.06))

                    if editMode {
                        EditableGridView(columns: columns, rows: $editingValues,
                                         originalRows: previewRows, onChange: { hasChanges = true })
                            .frame(maxHeight: .infinity)
                    } else {
                        ResultGridView(columns: previewCols, rows: previewRows)
                            .frame(maxHeight: .infinity)
                    }

                    if let saveMessage = saveMessage {
                        Text(saveMessage).font(.footnote).foregroundColor(.green)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                    }
                    if let saveError = saveError {
                        Text(saveError).font(.footnote).foregroundColor(.red)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var dataToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showFilter = true } label: { Label("筛选", systemImage: "line.3.horizontal.decrease.circle") }
        }
        // 导出为会员功能（PRO）。当前 isPro 默认 true，接入会员后按后端状态决定是否显示。
        // 注意：条件判断放在 ToolbarItem 内部（View 级别），避免在 ToolbarContent 顶层用 if（iOS 16 才支持）。
        ToolbarItem(placement: .navigationBarTrailing) {
            if AppConfig.isPro {
                Menu {
                    Button { exportAs(.csv) } label: { Label("导出 CSV", systemImage: "doc") }
                    Button { exportAs(.sql) } label: { Label("导出 SQL", systemImage: "swiftdata") }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            async let cols = connection.listColumns(db: db, table: table)
            async let prev = connection.preview(db: db, table: table, limit: 100,
                                                 whereClause: activeWhere, orderBy: activeOrderBy)
            async let cnt = connection.countRows(db: db, table: table, whereClause: activeWhere)
            let c = try await cols
            let p = try await prev
            let n = try await cnt
            var pc = [ColumnDef](); var pr = [[String?]]()
            if case .result(let cc, let rr) = p { pc = cc; pr = rr }
            await MainActor.run {
                self.columns = c
                self.previewCols = pc
                self.previewRows = pr
                self.rowCount = n
            }
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.error = msg }
        }
        await MainActor.run { loading = false }
    }

    private func exportAs(_ format: ExportFormat) {
        guard !previewCols.isEmpty else { return }
        let names = previewCols.map { $0.name }
        let ts = ExportUtils.timestamp()
        let fileName: String
        let content: String
        switch format {
        case .csv:
            fileName = "\(table)_\(ts).csv"
            content = ExportUtils.buildCSV(columnNames: names, rows: previewRows)
        case .sql:
            fileName = "\(table)_\(ts).sql"
            content = ExportUtils.buildSQL(insertInto: table, columnNames: names, rows: previewRows)
        }
        if let url = ExportUtils.writeTempFile(name: fileName, content: content) {
            ExportUtils.shareFile(url)
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
                _ = try await connection.query(sql)
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
