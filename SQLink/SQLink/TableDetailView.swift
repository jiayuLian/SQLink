import SwiftUI
import UIKit
import Combine

// MARK: - SQL WHERE / ORDER helpers

/// 把用户输入包成 LIKE 模式串，并统一转义通配符。
///
/// 之前用 `ESCAPE '\\'`：一是反斜杠本身要参与 SQL 字面量转义，二是
/// `NO_BACKSLASH_ESCAPES` 下 `'\\'` 会变成两个字符导致 ESCAPE 参数非法（整条语句报错）。
/// 改用 ASCII 的 `!` 当转义符，与 sql_mode 完全无关；`\` 仍按字面量规则转义。
private func likePattern(_ s: String, head: Bool, tail: Bool) -> String {
    var body = ""
    for ch in s {
        if ch == "!" || ch == "%" || ch == "_" { body.append("!") }
        body.append(ch)
    }
    // 反斜杠先按字面量规则转义（见 sqlLiteral 注释），再拼通配符
    body = body.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "'", with: "''")
    return "'" + (head ? "%" : "") + body + (tail ? "%" : "") + "' ESCAPE '!'"
}

/// 字符串字面量：单引号 `''` + 反斜杠转义（与导出、控制台编辑共用同一套规则）。
private func quoteValue(_ s: String) -> String { sqlLiteral(s) }

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
        case .contains:      sqlPart = "\(f) LIKE \(likePattern(c.value, head: true, tail: true))"
        case .notContains:   sqlPart = "\(f) NOT LIKE \(likePattern(c.value, head: true, tail: true))"
        case .startsWith:    sqlPart = "\(f) LIKE \(likePattern(c.value, head: false, tail: true))"
        case .notStartsWith: sqlPart = "\(f) NOT LIKE \(likePattern(c.value, head: false, tail: true))"
        case .endsWith:      sqlPart = "\(f) LIKE \(likePattern(c.value, head: true, tail: false))"
        case .notEndsWith:   sqlPart = "\(f) NOT LIKE \(likePattern(c.value, head: true, tail: false))"
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

// MARK: - DDL 美化与高亮（配色参考 Navicat 表结构 DDL 视图）

/// 自适应明暗主题的配色：浅色下取 Navicat 原色，深色下提亮以保证可读性。
private func ddlColor(light: UIColor, dark: UIColor) -> Color {
    Color(UIColor(dynamicProvider: { $0.userInterfaceStyle == .dark ? dark : light }))
}

/// 关键字 / 数据类型 / 运算符 —— 蓝（Navicat 关键字色 #097BF7）
private let ddlKeywordColor = ddlColor(light: UIColor(red: 0.04, green: 0.48, blue: 0.97, alpha: 1),
                                       dark: UIColor(red: 0.31, green: 0.66, blue: 1.00, alpha: 1))
/// 字符串字面量 —— 红（Navicat 字符串色 #FF1744）
private let ddlStringColor = ddlColor(light: UIColor(red: 1.00, green: 0.09, blue: 0.27, alpha: 1),
                                      dark: UIColor(red: 1.00, green: 0.42, blue: 0.49, alpha: 1))
/// 数字字面量 —— 绿（Navicat 数字色 #0BC853）
private let ddlNumberColor = ddlColor(light: UIColor(red: 0.04, green: 0.78, blue: 0.33, alpha: 1),
                                      dark: UIColor(red: 0.21, green: 0.82, blue: 0.48, alpha: 1))
/// 注释 —— 次要文本色
private let ddlCommentColor = Color.secondary

private let sqlKeywordSet: Set<String> = [
    "CREATE","TABLE","TEMPORARY","PRIMARY","KEY","NOT","NULL","DEFAULT","UNIQUE",
    "AUTO_INCREMENT","ENGINE","CHARSET","COLLATE","CONSTRAINT","FOREIGN","REFERENCES",
    "INDEX","UNSIGNED","ZEROFILL","ON","DELETE","UPDATE","CASCADE","COMMENT","IF",
    "EXISTS","ALGORITHM","LOCK","FULLTEXT","SPATIAL","VIEW","AS","SELECT","FROM",
    "WHERE","AND","OR","ORDER","BY","LIMIT","INNER","LEFT","RIGHT","OUTER","JOIN",
    "SET","VALUES","INSERT","INTO","REPLACE","DROP","ALTER","ADD","MODIFY","CHANGE",
    "DESC","ASC","DISTINCT","GROUP","HAVING","LIKE","IN","IS","BETWEEN",
    // 表选项 / 索引 / 分区等
    "USING","BTREE","HASH","ROW_FORMAT","PARTITION","RANGE","LIST","MAXVALUE",
    "GENERATED","STORED","VIRTUAL","ALWAYS","INVISIBLE","VISIBLE","CHECK",
    "TABLESPACE","ENCRYPTION","COMPRESSION","AVG_ROW_LENGTH","KEY_BLOCK_SIZE",
    "STATS_PERSISTENT","STATS_AUTO_RECALC","STATS_SAMPLE_PAGES","CHECKSUM",
    "DELAY_KEY_WRITE","PACK_KEYS","MAX_ROWS","MIN_ROWS","INSERT_METHOD","PARSER",
    "WITH","LESS","THAN","COLUMNS",
    // 默认值常用函数
    "CURRENT_TIMESTAMP","CURRENT_DATE","CURRENT_TIME","NOW","LOCALTIME",
    "LOCALTIMESTAMP","UTC_TIMESTAMP"
]

/// 数据类型（Navicat 中与关键字同为蓝色）
private let sqlTypeSet: Set<String> = [
    "BIT","BOOL","BOOLEAN","TINYINT","SMALLINT","MEDIUMINT","INT","INTEGER","BIGINT",
    "DECIMAL","DEC","NUMERIC","FLOAT","DOUBLE","REAL","SERIAL","FIXED",
    "DATE","DATETIME","TIMESTAMP","TIME","YEAR",
    "CHAR","VARCHAR","NCHAR","NVARCHAR","CHARACTER","VARYING","NATIONAL","LONG",
    "BINARY","VARBINARY","TINYBLOB","BLOB","MEDIUMBLOB","LONGBLOB","LONGTEXT",
    "TINYTEXT","TEXT","MEDIUMTEXT","ENUM","JSON","UUID","INET6",
    "GEOMETRY","POINT","LINESTRING","POLYGON","MULTIPOINT",
    "MULTILINESTRING","MULTIPOLYGON","GEOMETRYCOLLECTION"
]

/// 这些关键字后面直接跟「取值」而不带等号，如 CHARACTER SET utf8mb4、COLLATE xxx、USING BTREE。
private let sqlValueKeywordSet: Set<String> = ["CHARACTER", "SET", "COLLATE", "CHARSET", "ENGINE", "USING", "ROW_FORMAT"]

/// 运算符字符（= < > + - 等），在 DDL 中与关键字同色。
private let sqlOperatorChars: Set<Character> = ["=", "<", ">", "!", "+", "-", "*", "/", "%", "|", "&", "^", "~"]

private func isSQLOperator(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy { sqlOperatorChars.contains($0) }
}

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

/// 简易 SQL 语法高亮：关键字 / 数据类型 / 运算符 = 蓝，字符串 = 红，数字 = 绿，
/// 反引号标识符与标点保持默认前景色（与 Navicat 表结构 DDL 视图一致）。
private func highlightSQL(_ source: String) -> AttributedString {
    var result = AttributedString()
    let pattern = "(--[^\\n]*|#[^\\n]*|/\\*.*?\\*/|'[^']*'|`[^`]*`|\\d+(?:\\.\\d+)?|[A-Za-z_][A-Za-z0-9_]*|\\s+|[(),;.]|[=<>!+\\-*/%|&^~]+|[^\\s])"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return AttributedString(source)
    }
    let ns = source as NSString
    let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
    // 取值着色：Navicat 会把「选项取值」也着成蓝色，两种写法都要覆盖 ——
    //   带等号：ENGINE=InnoDB / CHARSET=utf8mb4 / ROW_FORMAT=DYNAMIC（数字仍保持绿色）
    //   不带等号：CHARACTER SET utf8mb4 / COLLATE utf8mb4_unicode_ci / USING BTREE
    var valuePending = false
    for m in matches {
        guard let range = Range(m.range, in: source) else { continue }
        let token = String(source[range])
        var attr = AttributedString(token)
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += attr                    // 空白原样保留，不打断取值判定
            continue
        }
        let isValue = valuePending
        valuePending = false
        if token.hasPrefix("`") {
            // 反引号标识符（库/表/字段名）：默认前景色；但作为取值时着蓝色
            if isValue { attr.foregroundColor = ddlKeywordColor }
        } else if token.hasPrefix("'") {
            attr.foregroundColor = ddlStringColor
        } else if token.hasPrefix("--") || token.hasPrefix("#") || token.hasPrefix("/*") {
            attr.foregroundColor = ddlCommentColor
        } else if Double(token) != nil {
            attr.foregroundColor = ddlNumberColor
        } else if isSQLOperator(token) {
            attr.foregroundColor = ddlKeywordColor
            if token == "=" { valuePending = true }
        } else {
            let upper = token.uppercased()
            if sqlKeywordSet.contains(upper) || sqlTypeSet.contains(upper) || isValue {
                attr.foregroundColor = ddlKeywordColor
            }
            if sqlValueKeywordSet.contains(upper) { valuePending = true }
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

    @EnvironmentObject var settings: AppSettings

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
    @GestureState private var ddlMagnify: CGFloat = 1.0

    // filter & sort (lifted here so they persist across sheet / navigation)
    @State private var showFilter = false
    @State private var filterConditions: [FilterCondition] = []
    @State private var sortField: String = ""
    @State private var sortDirection: SortDirection = .asc
    @State private var filterLogic: FilterLogic = .and
    @State private var activeWhere: String? = nil
    @State private var activeOrderBy: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 加载失败：之前只把错误塞进 @State 却不展示，页面会永远停在「结构（0 列）/ 加载中…」，
                // 也不给重试入口 —— 用户只能退出去再进来。
                if let err = error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("重试") { Task { await load() } }
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }

                // 结构卡片（对齐 Android 版：标题 + 列行 + 底部分隔线）
                VStack(alignment: .leading, spacing: 0) {
                    Text("结构（\(columns.count) 列）")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    if columns.isEmpty {
                        Text(error == nil ? "加载中…" : "未能获取表结构")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    Divider().padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)

                // 筛选 / 排序摘要（仅在已应用时出现）
                if !filterStatusSummary.isEmpty {
                    Text(filterStatusSummary)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                }

                // 三个入口：与 Android 版一致——各自独立卡片、图标 + 标题 + 右侧箭头，
                // 不再把「查看建表 SQL」做成结构卡片里的蓝色文字按钮。
                Button {
                    showDDL = true
                } label: {
                    entryRow(icon: "doc.plaintext", title: "查看建表 SQL")
                }
                .buttonStyle(PlainButtonStyle())
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)

                NavigationLink {
                    TableDataView(connection: connection, db: db, table: table,
                                  conditions: $filterConditions,
                                  sortField: $sortField,
                                  sortDirection: $sortDirection,
                                  filterLogic: $filterLogic,
                                  activeWhere: $activeWhere,
                                  activeOrderBy: $activeOrderBy)
                } label: {
                    entryRow(icon: "tablecells", title: "查看数据",
                             trailingText: rowCount.map { "匹配 \($0) 条" } ?? (error == nil ? "加载中…" : "未获取"))
                }
                .buttonStyle(PlainButtonStyle())
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)

                NavigationLink {
                    QueryConsoleView(connection: connection, db: db, defaultTable: table)
                } label: {
                    entryRow(icon: "terminal", title: "打开查询控制台",
                             badge: settings.isPro ? nil : "会员")
                }
                .buttonStyle(PlainButtonStyle())
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showFilter = true } label: {
                    Label("筛选&排序", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        // 筛选 / 排序任一变化都只触发一次加载（原来两个 onChange 各自 load 一遍，
        // 一次「应用」会打 4 条 SQL：结构+计数 各两遍）。
        .onChange(of: filterSignature) { _ in
            Task { await load() }
        }
        .task { await load() }

        // 筛选 & 排序弹窗：改用系统 sheet（见 filterSheet 注释）。
        .sheet(isPresented: $showFilter) { filterSheet }
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
                                .font(.system(size: 13 * ddlScale * ddlMagnify, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                                .padding(8)
                                .contentShape(Rectangle())
                                .gesture(
                                    MagnificationGesture()
                                        .updating($ddlMagnify) { value, state, _ in state = value }
                                        .onEnded { value in
                                            ddlScale = min(max(ddlScale * value, 0.6), 3.0)
                                        }
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
            let sql = try await withReconnect(connection) { try await connection.showCreateTable(db: db, table: table) }
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

    /// 表详情页入口行（对齐 Android 版 ListTile）：图标 + 标题 + 右侧说明/徽标 + 箭头。
    private func entryRow(icon: String, title: String,
                          trailingText: String? = nil,
                          badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.primary)
                .frame(width: 24, alignment: .center)
            Text(title).font(.system(size: 16))
            Spacer(minLength: 8)
            if let badge = badge {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(badge).font(.system(size: 12))
                }
                .foregroundColor(.orange)
            }
            if let trailingText = trailingText {
                Text(trailingText).font(.system(size: 14)).foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
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

    /// 筛选 + 排序的合并签名，用于只触发一次重载。
    private var filterSignature: String {
        "\(activeWhere ?? "")|\(activeOrderBy ?? "")"
    }

    /// 筛选 & 排序弹窗：用系统 `.sheet` 呈现。
    /// 旧实现是自定义 `.overlay`（全屏变暗色 + 卡片）叠在 NavigationView 的内容层上，
    /// 其上还带一个 `.onTapGesture` 关闭手势；这种手写模态与宿主 List 的手势/命中测试
    /// 会互相干扰，导致「取消/清除/应用」偶发点不动（必须退出重进才恢复）。
    /// 系统 sheet 由 UIKit 独立呈现，不受宿主视图重绘与手势层影响，从根上规避该问题。
    private var filterSheet: some View {
        TableFilterView(columns: columns,
                        conditions: $filterConditions,
                        sortField: $sortField,
                        sortDirection: $sortDirection,
                        filterLogic: $filterLogic,
                        isPresented: $showFilter,
                        db: db, table: table, connection: connection,
                        onApply: { w, o in
                            activeWhere = w; activeOrderBy = o
                        })
    }

    private func load() async {
        await MainActor.run { loading = true; error = nil }
        do {
            // 表结构在一次会话内基本不变：只在还没拿到时查一次。
            // 改筛选 / 排序时只需要重算「匹配条数」，不必连表结构一起重查。
            if columns.isEmpty {
                let c = try await withReconnect(connection) { try await connection.listColumns(db: db, table: table) }
                await MainActor.run { self.columns = c }
            }
            let n = try await withReconnect(connection) {
                try await connection.countRows(db: db, table: table, whereClause: activeWhere)
            }
            await MainActor.run { self.rowCount = n }
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
                // 必须用 .borderless：否则在 List/Form 行里整行都会被当成这个按钮的点击区域
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.red)   // borderless 会丢掉 role 的破坏色，显式锁红
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

    // 页码跳转（长表不必点几十次「下一页」）；用居中卡片弹窗，不再用整屏 sheet
    @State private var showJumpSheet = false
    @State private var jumpText = ""
    // 键盘高度：弹窗要跟着键盘上移，否则小屏会被挡住
    @State private var keyboardInset: CGFloat = 0
    @FocusState private var jumpFocused: Bool

    // 点「编辑」但不满足条件时，把原因讲清楚（按钮不再凭空消失）
    @State private var editBlockMessage: String?
    @State private var showEditBlocked = false

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

    /// 所有主键列。复合主键（>1 列）不能只按第一列定位行 —— 会误改到别的行。
    private var primaryKeyColumns: [String] {
        columns.filter { $0.key == "PRI" }.map { $0.field }
    }

    /// 用于定位行的唯一键：单列主键优先，其次单列唯一键；复合主键返回 nil（禁止编辑）。
    private var primaryKey: String? {
        if primaryKeyColumns.count == 1 { return primaryKeyColumns[0] }
        if primaryKeyColumns.isEmpty { return columns.first { $0.key == "UNI" }?.field }
        return nil
    }

    /// 是否已应用筛选或排序条件（带 WHERE 或 ORDER BY）。整表裸查为 false，不显示编辑按钮。
    private var hasFilterCondition: Bool {
        !(activeWhere?.isEmpty ?? true) || !(activeOrderBy?.isEmpty ?? true)
    }

    /// 筛选 + 排序的合并签名，用于只触发一次重载。
    private var filterSignature: String {
        "\(activeWhere ?? "")|\(activeOrderBy ?? "")"
    }

    /// 为什么不能编辑（nil = 可以编辑）。顺序按用户最容易撞上的来。
    private var editBlockReason: String? {
        if !settings.isPro { return "数据编辑为会员功能，升级后可修改数据" }
        if loading { return "数据还在加载，请稍候" }
        if error != nil { return "当前数据加载失败，无法编辑" }
        if primaryKeyColumns.count > 1 {
            return "该表是复合主键（\(primaryKeyColumns.joined(separator: " + "))），按单列定位可能会改到其它行，请在 SQL 控制台修改"
        }
        if !hasFilterCondition { return "为避免误改整张表，请先用「筛选&排序」设置条件并应用" }
        if primaryKey == nil { return "结果集里没有主键/唯一键列，无法定位要更新的行" }
        return nil
    }

    var body: some View {
        mainContent
            .navigationTitle(table)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dataToolbar }
            // 筛选 + 排序一次「应用」只触发一次加载（原来两个 onChange 会各跑一遍）
            .onChange(of: filterSignature) { _ in
                // 回到第 1 页由 page 的 onChange 负责加载；本来就在第 1 页时才直接加载，
                // 避免「重置页码 + 显式加载」重复请求两次。
                if page != 1 { page = 1 } else { Task { await load() } }
            }
            .onChange(of: page) { _ in
                Task { await load() }
            }            .onChange(of: settings.pageSize) { _ in Task { await load() } }
            .task { await load() }
            .sheet(isPresented: $showFilter) { filterSheet }
            // 跳页用「居中卡片 + 遮罩」，与 Android 版一致；iOS 15 没有 presentationDetents，
            // 系统 sheet 在 iPhone 上必然是接近满屏的卡片，用户反馈太占屏幕。
            .overlay {
                if showJumpSheet { jumpDialog }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenH = UIScreen.main.bounds.height
                keyboardInset = max(0, screenH - frame.origin.y)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardInset = 0
            }
            .alert("无法编辑", isPresented: $showEditBlocked) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(editBlockMessage ?? "")
            }
    }

    /// 跳页弹窗：居中卡片（标题 + 页码输入框 + 首页 / 末页 / 跳转），
    /// 背景半透明遮罩，点遮罩关闭；点击外部即等同「取消」。
    private var jumpDialog: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { closeJumpDialog() }

            VStack(alignment: .leading, spacing: 16) {
                Text("跳转到页码")
                    .font(.system(size: 17, weight: .semibold))

                TextField("页码（1 - \(maxPage)）", text: $jumpText)
                    .keyboardType(.numberPad)
                    .font(.system(size: 16, design: .monospaced))
                    .focused($jumpFocused)
                    .onAppear {
                        // 与 Android 一致：弹出即聚焦，直接敲数字
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { jumpFocused = true }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                    )

                HStack(spacing: 20) {
                    Button("首页") { applyJump(to: 1) }
                    Button("末页") { applyJump(to: maxPage) }
                    Spacer(minLength: 0)
                    Button("跳转") { jumpToTypedPage() }
                }
                .font(.system(size: 15))
            }
            .padding(20)
            .frame(maxWidth: 280)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 6)
            .padding(.horizontal, 30)
            // 键盘弹出时把卡片往上顶，避免遮挡输入框与按钮
            .offset(y: -min(keyboardInset, 320) / 2)
        }
        .transition(.opacity)
    }

    private func applyJump(to target: Int) {
        page = min(max(1, target), maxPage)
        closeJumpDialog()
    }

    private func closeJumpDialog() {
        showJumpSheet = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func jumpToTypedPage() {
        let trimmed = jumpText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed) {
            page = min(max(1, v), maxPage)
        }
        closeJumpDialog()
    }

    private var mainContent: some View {
        Group {
            if loading && previewCols.isEmpty {
                // 只有「首次进入、还没有任何数据」时才整屏等待。
                // 原来每次翻页 / 刷新都退回整屏「加载中…」，表格会整块闪掉再重画。
                ProgressView("加载中…")
            } else if previewCols.isEmpty, let error = error {
                // 一条都没取到又出错：给明确原因 + 重试
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundColor(.orange)
                    Text(error).font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                VStack(spacing: 0) {
                    // 刷新中：顶部细进度条，旧内容留在原地
                    if loading { ProgressView().progressViewStyle(.linear) }
                    // 刷新失败但已有数据：只在顶部提示，不清空表格
                    if let error = error {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill").font(.caption2)
                            Text("刷新失败：\(error)").font(.caption2).lineLimit(2)
                            Spacer(minLength: 6)
                            Button("重试") { Task { await load() } }.font(.caption2)
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
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
                            Text("免费版最多查看 \(settings.plan.freeViewLimit) 条，另有 \(rawCount - settings.plan.freeViewLimit) 条已隐藏，升级会员查看全部")
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                    }

                    // 免费版数据编辑提示：编辑按钮现在常显，点它也会说明是会员功能；
                    // 这里保留一行常驻说明，避免用户反复点。
                    if !settings.isPro {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill").font(.caption2)
                            Text("数据编辑为会员功能，升级后可修改数据")
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
                                        gridScale = min(max(gridScale * value, 0.5), 3.0)
                                    }
                            )
                            .onTapGesture(count: 2) { gridScale = 1 }
                            // 右下角手动缩放（双指捏合仍然可用）
                            .overlay(alignment: .bottomTrailing) {
                                GridZoomControls(scale: $gridScale)
                                    .padding(.trailing, 10)
                                    .padding(.bottom, 10)
                            }
                    } else {
                        ResultGridView(columns: previewCols, rows: previewRows, primaryKey: primaryKey, scale: gridScale * gridMagnify)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .updating($gridMagnify) { value, state, _ in state = value }
                                    .onEnded { value in
                                        gridScale = min(max(gridScale * value, 0.5), 3.0)
                                    }
                            )
                            .onTapGesture(count: 2) { gridScale = 1 }
                            // 右下角手动缩放（双指捏合仍然可用）
                            .overlay(alignment: .bottomTrailing) {
                                GridZoomControls(scale: $gridScale)
                                    .padding(.trailing, 10)
                                    .padding(.bottom, 10)
                            }
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
                    // 字号跟随表格缩放（夹在 0.85~1.2）：缩小到 90% / 75% 时底栏字一起收，
                    // 且所有文案强制单行 —— 否则「上一页 / 下一页」会被挤成「上一\n页」。
                    Divider()
                    HStack(spacing: 8) {
                        Button { if page > 1 { page -= 1 } } label: {
                            barLabel("上一页", icon: "chevron.left")
                        }
                        .disabled(page <= 1 || loading || editMode)
                        // 页码可点 → 输入页码 / 首页 / 末页
                        Button {
                            jumpText = "\(page)"
                            showJumpSheet = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("\(page) / \(maxPage)")
                                    .font(.system(size: 12.5 * barScale))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8 * barScale))
                            }
                            .minimumScaleFactor(0.75)
                        }
                        .disabled(loading || editMode)
                        Button { if page < maxPage { page += 1 } } label: {
                            barLabel("下一页", icon: "chevron.right")
                        }
                        .disabled(page >= maxPage || loading || editMode)
                        Spacer(minLength: 4)
                        if editMode {
                            // 编辑期间必须锁定翻页/改每页条数/改筛选，否则新页数据会与旧编辑值错位写库。
                            Text("编辑中已锁定翻页")
                                .font(.system(size: 10.5 * barScale))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        Menu { ForEach(pageSizeOptions, id: \.self) { s in
                            Button("\(s) 条/页") { settings.pageSize = s; page = 1 }
                        } } label: {
                            barLabel("\(effectivePageSize) 条/页", icon: "line.3.horizontal")
                        }
                        .disabled(editMode)
                        // 缩放复位不放在底栏了：右下角悬浮控件的百分比点一下就复位 100%（也有双击表格），
                        // 这里再放一个会把宽度挤爆 —— 正是「上一页」被折成两行的元凶。
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(Color.gray.opacity(0.04))
                }
                // 导出进度遮罩：仅导出中显示，需要拦住底层点击，故继续用 overlay（短时、无交互按钮）
                .overlay {
                    if exportState.isExporting { exportOverlay }
                }
            }
        }
    }

    /// 筛选 & 排序弹窗：与表结构页一致，用系统 `.sheet`（理由见 TableDetailView.filterSheet 注释）。
    private var filterSheet: some View {
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

    /// 免费查看上限（会员无上限）。与后端 `freeViewLimit` 同步。
    private var viewLimit: Int {
        settings.isPro ? Int.max : max(1, settings.plan.freeViewLimit)
    }
    /// 免费 / 未登录用户分页档位：固定 50、100 两档（硬编码，不随后端 freeViewLimit 漂移）。
    private static let freePageSizeOptions = [50, 100]
    /// 免费用户每页条数硬上限 = 免费档位最大值（由档位推导，避免两处写死不同步）。
    private static var freePageSizeCap: Int { freePageSizeOptions.max() ?? 100 }
    /// 会员分页档位：不受免费额度限制。
    private static let proPageSizeOptions = [50, 100, 200, 500]

    /// 实际每页条数：免费用户固定上限 100（与可选档位一致），会员不受限。
    /// 仍做一次兜底夹取，防止历史持久化值（如会员期选的 500）在会员到期后继续按 500 取数，绕开免费额度。
    private var effectivePageSize: Int {
        let base = max(1, settings.pageSize)
        return settings.isPro ? base : min(base, Self.freePageSizeCap)
    }
    /// 「每页条数」菜单可选档位：免费 / 未登录用户只有 50、100 两档，会员不受限。
    private var pageSizeOptions: [Int] {
        settings.isPro ? Self.proPageSizeOptions : Self.freePageSizeOptions
    }
    private var maxPage: Int {
        max(1, Int(ceil(Double(rowCount ?? 0) / Double(effectivePageSize))))
    }

    /// 底栏字号缩放系数：跟随表格缩放，但夹在 0.85~1.2，
    /// 保证 50% 时仍看得清、300% 时底栏也不会撑爆。
    private var barScale: CGFloat {
        min(max(gridScale, 0.85), 1.2)
    }

    /// 底栏「图标 + 文字」统一构件：强制单行 + 允许小幅压缩，
    /// 宽度再紧也不会折成两行（缩放按钮出现时最容易触发）。
    private func barLabel(_ text: String, icon: String, iconSize: CGFloat = 11) -> some View {
        HStack(spacing: 3 * barScale) {
            Image(systemName: icon)
                .font(.system(size: iconSize * barScale, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5 * barScale))
                .lineLimit(1)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
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
            .disabled(editMode)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if editMode {
                Button("取消") { cancelEdit() }
            } else {
                // 编辑按钮常显：不满足条件时点一下说明原因，
                // 而不是让按钮凭空消失（用户只会觉得「这页怎么不能编辑」）。
                Button {
                    if let reason = editBlockReason {
                        editBlockMessage = reason
                        showEditBlocked = true
                    } else {
                        enterEdit()
                    }
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
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

    private func load() async {
        // 数据即将整体替换：若正处于编辑态先退出编辑（翻页/筛选入口已锁定，此处为兜底），
        // 避免「旧编辑值 × 新页主键」错位写库；同时保证状态写入在主线程。
        await MainActor.run {
            if editMode { cancelEdit() }
            loading = true
            error = nil
        }
        do {
            try await fetchData()
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        await MainActor.run { loading = false }
    }

    private func fetchData() async throws {
        let pageSize = effectivePageSize
        // 先取真实总数，用于免费版浏览上限判断
        let raw = try await withReconnect(connection) { try await connection.countRows(db: db, table: table, whereClause: activeWhere) }
        let limit = viewLimit
        let displayTotal = min(raw, limit)
        let computedMaxPage = max(1, Int(ceil(Double(displayTotal) / Double(pageSize))))
        let safePage = min(max(1, page), computedMaxPage)
        if safePage != page { await MainActor.run { page = safePage } }
        let offset = (safePage - 1) * pageSize
        // 关键修复：实际拉取的行数同样按免费额度裁剪。
        // 之前只裁了「总数 / 页数」，没有裁 fetch 的 limit —— 免费用户把每页设成 500 时一次就能取回 500 行。
        let fetchLimit = max(0, min(pageSize, limit - offset))

        // 表结构只在还没拿到时查一次：翻页 / 刷新没必要重复 `SHOW FULL COLUMNS`
        // （一次「应用筛选」原本会多打两条结构查询）。
        if columns.isEmpty {
            let c = try await withReconnect(connection) {
                try await connection.listColumns(db: db, table: table)
            }
            await MainActor.run { self.columns = c }
        }
        let p = try await withReconnect(connection) {
            try await connection.fetchRows(db: db, table: table, limit: fetchLimit, offset: offset,
                                           whereClause: activeWhere, orderBy: activeOrderBy)
        }
        var pc = [ColumnDef](); var pr = [[String?]]()
        if case .result(let cc, let rr) = p { pc = cc; pr = rr }
        await MainActor.run {
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
        // 兜底：入口按钮已按会员状态隐藏，这里再挡一层（防止状态回滚 / 历史状态残留后仍能进编辑态）。
        guard settings.isPro else {
            saveMessage = nil
            saveError = "数据编辑为会员功能，升级后可修改数据"
            return
        }
        // 结果集列数必须与表结构列数一致（INVISIBLE 列、列级 SELECT 权限等都会导致不一致），
        // 否则保存时会按结构列索引去读结果行 → 越界或写错列。
        guard previewCols.count == columns.count, !previewRows.isEmpty else {
            saveMessage = nil
            saveError = "当前结果与表结构列数不一致，暂不支持编辑"
            return
        }
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
        // 兜底：会员状态在编辑期间失效（降级 / 登出）时不写库。
        guard settings.isPro else {
            await MainActor.run { saveError = "数据编辑为会员功能，升级后可修改数据" }
            return
        }
        guard let pk = primaryKey else {
            await MainActor.run { saveError = "未检测到主键或唯一键" }
            return
        }
        guard let pkIndex = columns.firstIndex(where: { $0.field == pk }) else {
            await MainActor.run { saveError = "主键列索引异常" }
            return
        }
        do {
            var failed = 0
            for ri in 0..<editingValues.count {
                guard ri < previewRows.count else { continue }
                let oldRow = previewRows[ri]
                let newRow = editingValues[ri]
                // 主键为 NULL 时无法定位行：跳过并计入失败，避免拼出 WHERE pk = '' 的「假成功」
                guard pkIndex < oldRow.count, let pkRaw = oldRow[pkIndex] else { failed += 1; continue }
                var sets: [String] = []
                for ci in 0..<columns.count {
                    let old = ci < oldRow.count ? oldRow[ci] : nil
                    let new = ci < newRow.count ? newRow[ci] : nil
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
                let pkVal = quoteValue(pkRaw)
                let sql = "UPDATE `\(db.replacingOccurrences(of: "`", with: "``"))`.`\(table.replacingOccurrences(of: "`", with: "``"))` SET \(sets.joined(separator: ", ")) WHERE `\(pk.replacingOccurrences(of: "`", with: "``"))` = \(pkVal) LIMIT 1"
                let r = try await withReconnect(connection) { try await connection.query(sql) }
                // 影响行数为 0 表示没匹配到任何记录（例如主键值含空白、并发被改动），不能报「保存成功」
                if case .ok(let n) = r, n == 0 { failed += 1 }
            }
            await MainActor.run {
                saveMessage = failed == 0 ? "保存成功" : "保存完成（\(failed) 行未匹配到记录，未生效）"
                saveError = nil
                editMode = false
            }
            await load()
        } catch {
            await MainActor.run { saveError = "保存失败：\(error.localizedDescription)" }
        }
    }
}

// MARK: - 死连接自动重连（模块级，供所有视图共用）

/// 连接断开（写入数据失败 / 被服务器关闭）时自动重连一次再重试，避免「点击查看数据却报写入失败」。
func withReconnect<T>(_ connection: MySQLConnection, _ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let e as MySQLError where e.isDeadConnection {
        try await connection.reconnect()
        return try await body()
    }
}
