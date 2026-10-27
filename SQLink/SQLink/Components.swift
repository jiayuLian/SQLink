import SwiftUI
import UIKit

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

/// Connection row shown in the main list.
/// 编辑入口只保留侧滑 / 长按菜单：行内铅笔按钮嵌在 NavigationLink 里在 List 中几乎点不动，
/// 属于无效控件，已移除（避免「点了没反应」的误判）。
struct ConnectionRow: View {
    let profile: ConnectionProfile
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? profile.host : profile.name)
                    .font(.headline)
                Text("\(profile.user)@\(profile.host):\(profile.port)\(profile.database.isEmpty ? "" : "/\(profile.database)")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if profile.useTLS {
                Image(systemName: "lock.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Clean, scrollable result grid (Navicat-style). 真实主键列以 🔑 标记并高亮，便于一眼确认真实 ID。
/// 长文本会被截断显示，点击/长按单元格可查看完整值并复制。
struct ResultGridView: View {
    let columns: [ColumnDef]
    let rows: [[String?]]
    var primaryKey: String? = nil
    var scale: CGFloat = 1.0

    @State private var selectedCell: SelectedCell? = nil

    private var pkIndex: Int? {
        guard let pk = primaryKey else { return nil }
        return columns.firstIndex { $0.name == pk }
    }

    /// 每列在 100% 时需要的宽度（表头 + 前 40 行内容里最宽的那个，夹在 56~220）。
    /// 之前固定 80~160：`id`/`status`/`age` 这类短列也占 160，8 列宽表在手机上
    /// 一屏只能看到 2 列多 —— 缩到 50% 也只是把浪费等比缩小。
    private var baseColWidths: [CGFloat] {
        columns.enumerated().map { ci, c in
            var units = displayUnits((primaryKey == c.name ? "🔑 " : "") + c.name)
            let sample = min(rows.count, 40)
            for ri in 0..<max(sample, 0) {
                let v = ci < rows[ri].count ? rows[ri][ci] : nil
                units = max(units, displayUnits(v ?? "NULL"))
            }
            // 等宽 12pt 半角约 7.4pt；全角字符按 1.9 个单元估。
            return min(max(units * 7.4 + 12, 56), 220)
        }
    }

    /// 按显示宽度折算字符单元：CJK / emoji 占两格。
    private func displayUnits(_ s: String) -> CGFloat {
        var n: CGFloat = 0
        for ch in s.unicodeScalars {
            n += ch.value >= 0x2E80 ? 1.9 : 1
        }
        return n
    }

    var body: some View {
        if columns.isEmpty {
            Text("无结果集").foregroundColor(.secondary).padding()
        } else {
            content(baseColWidths)
        }
    }

    private func content(_ widths: [CGFloat]) -> some View {
        // 宽度只量一次，传给表头和数据行，避免每个单元格重复估算。
        // 外层只负责横向滚动：表头和数据行在同一个横向坐标系里，
        // 左右滑动时列名与内容始终对齐。
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 表头固定在顶部，不参与纵向滚动。
                headerRow(widths)
                // 内层只负责纵向滚动：往下滑数据时字段名保持可见。
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<rows.count, id: \.self) { ri in
                            dataRow(ri: ri, widths: widths)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $selectedCell) { cell in
            CellValueSheet(column: columns[safe: cell.col]?.name ?? "", value: cell.value)
        }
    }

    private func headerRow(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { ci in
                headerCell(ci, width: widths[safe: ci] ?? 80)
            }
        }
    }

    @ViewBuilder
    private func headerCell(_ ci: Int, width: CGFloat) -> some View {
        let c = columns[ci]
        let isPK = primaryKey.map { c.name == $0 } ?? false
        let label = (isPK ? "🔑 " : "") + c.name
        Text(label)
            .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width * scale, alignment: .leading)
            .padding(6 * scale)
            .background(isPK ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
    }

    private func dataRow(ri: Int, widths: [CGFloat]) -> some View {
        let row = rows[ri]
        return HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                // 用安全判断：结果行列数理论上与列定义一致，但列级权限/异常响应下可能偏少，避免越界崩溃
                resultCell(ri: ri, ci: ci, value: ci < row.count ? row[ci] : nil,
                           width: widths[safe: ci] ?? 80)
            }
        }
    }

    @ViewBuilder
    private func resultCell(ri: Int, ci: Int, value: String?, width: CGFloat) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        let display = value == nil ? "NULL" : (value! ?? "")
        let text = Text(display)
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(value == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
        let background = isPK ? Color.accentColor.opacity(0.10) : ((ri + ci) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear)

        text
            .frame(width: width * scale, alignment: .leading)
            .padding(6 * scale)
            .background(background)
            .contextMenu { resultCellMenu(value: value, row: ri, col: ci) }
            .onTapGesture { selectedCell = SelectedCell(row: ri, col: ci, value: value) }
    }

    @ViewBuilder
    private func resultCellMenu(value: String?, row: Int, col: Int) -> some View {
        if let value = value {
            Button { UIPasteboard.general.string = value }
                label: { Label("复制值", systemImage: "doc.on.doc") }
            Button { selectedCell = SelectedCell(row: row, col: col, value: value) }
                label: { Label("查看完整值", systemImage: "eye") }
        } else {
            Button { } label: { Label("NULL（无值）", systemImage: "nosign") }
                .disabled(true)
        }
    }
}

/// 结果表格右下角的缩放按钮组（＋ / 百分比 / －）。
/// 双指捏合缩放手势仍然保留，这里只是提供一个「点一下」的等价入口：
/// 模拟器、单手操作或手势不好触发时可以直接点按钮放大/缩小，点百分比复位到 100%。
struct GridZoomControls: View {
    @Binding var scale: CGFloat

    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 3.0

    /// 预设档位：缩得越小步长越小，保证每一下都有明显变化，且 100% 一定命中。
    /// （固定 0.2 步进在 0.5 下界会走出 50%→70%→90%→110%，永远点不到 100%。）
    private let stops: [CGFloat] = [0.5, 0.6, 0.75, 0.9, 1.0, 1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.0]

    private var canZoomIn: Bool { scale < maxScale - 0.001 }
    private var canZoomOut: Bool { scale > minScale + 0.001 }

    private func nextStop(zoomIn: Bool) -> CGFloat {
        if zoomIn {
            return stops.first { $0 > scale + 0.001 } ?? maxScale
        }
        return stops.last { $0 < scale - 0.001 } ?? minScale
    }

    var body: some View {
        VStack(spacing: 0) {
            zoomButton(systemName: "plus", enabled: canZoomIn) {
                scale = min(max(nextStop(zoomIn: true), minScale), maxScale)
            }

            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 24)
                .contentShape(Rectangle())
                .onTapGesture { scale = 1.0 }

            zoomButton(systemName: "minus", enabled: canZoomOut) {
                scale = min(max(nextStop(zoomIn: false), minScale), maxScale)
            }
        }
        .frame(width: 40)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func zoomButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(enabled ? .accentColor : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }
}

/// Inline-editable result grid for TableDetailView editing mode. 真实主键列以 🔑🔒 标记并高亮。
/// 单元格宽度受限，长文本截断显示；长按非主键单元格可选择「编辑完整值」，在弹窗中用多行编辑器修改。
struct EditableGridView: View {
    let columns: [ColumnInfo]
    @Binding var rows: [[String?]]
    let originalRows: [[String?]]
    var primaryKey: String? = nil
    var scale: CGFloat = 1.0
    let onChange: () -> Void

    @State private var editTarget: EditTarget? = nil

    private var pkIndex: Int? {
        guard let pk = primaryKey else { return nil }
        return columns.firstIndex { $0.field == pk }
    }

    /// 与 ResultGridView 同款自适应列宽。编辑态用 originalRows 取值，
    /// 避免用户一边打字一边把列宽撑开/缩回。
    private var baseColWidths: [CGFloat] {
        columns.enumerated().map { ci, c in
            var units = displayUnits((primaryKey == c.field ? "🔑🔒 " : "") + c.field)
            let sample = min(originalRows.count, 40)
            for ri in 0..<max(sample, 0) {
                let v = ci < originalRows[ri].count ? originalRows[ri][ci] : nil
                units = max(units, displayUnits(v ?? "NULL"))
            }
            return min(max(units * 7.4 + 12, 56), 220)
        }
    }

    private func displayUnits(_ s: String) -> CGFloat {
        var n: CGFloat = 0
        for ch in s.unicodeScalars {
            n += ch.value >= 0x2E80 ? 1.9 : 1
        }
        return n
    }

    private func binding(for ri: Int, _ ci: Int) -> Binding<String> {
        Binding(
            get: {
                guard ri < rows.count, ci < rows[ri].count else { return "" }
                return rows[ri][ci] ?? ""
            },
            set: { new in
                guard ri < rows.count, ci < rows[ri].count else { return }
                let wasNull = (ri < originalRows.count && ci < originalRows[ri].count)
                    ? originalRows[ri][ci] == nil : false
                if new.isEmpty && wasNull {
                    rows[ri][ci] = nil
                } else {
                    rows[ri][ci] = new
                }
                onChange()
            }
        )
    }

    var body: some View {
        // 宽度只量一次（用 originalRows，不会因打字而抖动），再传给表头/数据行。
        content(baseColWidths)
    }

    private func content(_ widths: [CGFloat]) -> some View {
        // 与 ResultGridView 相同：外层横向、内层纵向，表头固定不动。
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(widths)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<rows.count, id: \.self) { ri in
                            dataRow(ri: ri, widths: widths)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 320)
        .border(Color.gray.opacity(0.3), width: 0.5)
        .sheet(item: $editTarget) { target in
            CellEditSheet(title: columns[safe: target.ci]?.field ?? "", text: binding(for: target.ri, target.ci))
        }
    }

    private func headerRow(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                editableHeaderCell(ci, width: widths[safe: ci] ?? 80)
            }
        }
    }

    @ViewBuilder
    private func editableHeaderCell(_ ci: Int, width: CGFloat) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        let label = (isPK ? "🔑🔒 " : "") + columns[ci].field
        Text(label)
            .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width * scale, alignment: .leading)
            .padding(6 * scale)
            .background(isPK ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
    }

    private func dataRow(ri: Int, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                editableCell(ri: ri, ci: ci, width: widths[safe: ci] ?? 80)
            }
        }
    }

    @ViewBuilder
    private func editableCell(ri: Int, ci: Int, width: CGFloat) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        if isPK {
            pkCell(ri: ri, ci: ci, width: width)
        } else {
            valueCell(ri: ri, ci: ci, width: width)
        }
    }

    @ViewBuilder
    private func pkCell(ri: Int, ci: Int, width: CGFloat) -> some View {
        let cell: String? = ci < rows[ri].count ? rows[ri][ci] : nil
        let text = cell ?? "NULL"
        Text(text)
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width * scale, alignment: .leading)
            .padding(6 * scale)
            .background(Color.accentColor.opacity(0.10))
    }

    @ViewBuilder
    private func valueCell(ri: Int, ci: Int, width: CGFloat) -> some View {
        let background = (ri + ci) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear
        let cell: String? = ci < rows[ri].count ? rows[ri][ci] : nil
        TextField(cell == nil ? "NULL" : "",
                  text: binding(for: ri, ci))
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(cell == nil ? .secondary : .primary)
            .lineLimit(1)
            .frame(width: width * scale, alignment: .leading)
            .padding(6 * scale)
            .background(background)
            .contextMenu {
                Button { editTarget = EditTarget(ri: ri, ci: ci) }
                    label: { Label("编辑完整值", systemImage: "square.and.pencil") }
            }
    }
}

// MARK: - 单元格完整值查看 / 编辑弹窗

/// 只读模式下查看单元格完整值并复制。
struct CellValueSheet: View {
    let column: String
    let value: String?
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(column)) {
                    if let value = value, !value.isEmpty {
                        TextEditor(text: .constant(value))
                            .font(.system(size: 14, design: .monospaced))
                            .frame(minHeight: 200)
                    } else {
                        Text(value == nil ? "NULL" : "空字符串")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.string = value ?? ""
                    } label: {
                        Label("复制完整值", systemImage: "doc.on.doc")
                    }
                    .disabled(value == nil)
                }
            }
            .navigationTitle(column)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

/// 编辑模式下用多行文本编辑器修改长单元格。
struct CellEditSheet: View {
    let title: String
    @Binding var text: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

private struct SelectedCell: Identifiable {
    let id = UUID()
    let row: Int
    let col: Int
    let value: String?
}

private struct EditTarget: Identifiable {
    let id = UUID()
    let ri: Int
    let ci: Int
}

// MARK: - 分组卡片列表（数据表 / 数据库列表共用）
//
// 为什么不用 List(.insetGrouped)：它的首段顶部会额外留出约 51pt 空白
// （分组样式自身的段上边距 + 搜索栏挂在导航栏抽屉里时占掉的高度），
// 而 SwiftUI 在 iOS 15 上没有 API 能把这段间距调小（.listSectionSpacing / .contentMargins
// 都要 iOS 17）。改成自绘卡片后，搜索栏与卡片之间的距离完全由下面的常量决定。
//
// 几何取值来自真机截图逐像素测量（iPhone 13/14，1170×2532 @3x）：
//   卡片左右内缩 16pt、圆角 10pt、行高 49pt、行内左右内边距 16pt、
//   图标槽宽 30pt（图标—文字间距 12pt）、分隔线左侧内缩 16pt。

/// 分组卡片的统一几何参数。改这里即可整体调整两个列表页的观感。
enum CardListMetrics {
    /// 卡片距屏幕左右
    static let cardInset: CGFloat = 16
    /// 卡片圆角
    static let corner: CGFloat = 10
    /// 行内左右内边距
    static let rowPadding: CGFloat = 16
    /// 图标槽宽（图标居中于槽内，实测图标墨迹距卡片左缘约 20pt）
    static let iconSlot: CGFloat = 30
    /// 图标与文字间距
    static let iconGap: CGFloat = 12
    /// 行高
    static let rowHeight: CGFloat = 49
    /// 分隔线左侧内缩（相对卡片左缘）
    static let separatorLeading: CGFloat = 16
    /// 搜索框下方的留白
    static let searchBottomGap: CGFloat = 8
    /// 卡片上方的留白（与上一项相加 = 搜索框到卡片的实际间距 18pt，改前约 51pt）
    static let cardTopGap: CGFloat = 10
}

/// 常驻搜索框（自绘）：固定显示在列表上方，不随滚动收起，也不靠导航栏抽屉。
///
/// 外观对齐系统搜索框：高 36pt、圆角 10pt、底色 systemGray5、左侧放大镜、非空时右侧清除按钮。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Color(.secondaryLabel))
            TextField(placeholder, text: $text)
                .font(.body)
                .foregroundColor(.primary)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 把若干行合成一张白色圆角卡片。
/// 用 secondarySystemGroupedBackground：浅色下为白色、深色下为分组内容色，与页面底色区分得开。
struct CardList<Content: View>: View {
    var topSpacing: CGFloat = CardListMetrics.cardTopGap
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: CardListMetrics.corner, style: .continuous))
            .padding(.top, topSpacing)
            .padding(.horizontal, CardListMetrics.cardInset)
    }
}

/// 行与行之间的分隔线（左侧内缩，与系统分组列表一致）。
struct CardRowDivider: View {
    var body: some View {
        Divider().padding(.leading, CardListMetrics.separatorLeading)
    }
}

/// 行按压反馈：按下时整行变浅灰，替代 List 自带的高亮。
struct CardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = configuration.isPressed
            ? Color(.systemGray4)
            : Color(.secondarySystemGroupedBackground)
        return configuration.label
            .background(bg)
            .contentShape(Rectangle())
    }
}

/// 延迟构造 destination。
///
/// `NavigationLink(destination:)` 放在 `List` / 卡片列表里时，destination 这个 struct 会在
/// 列表**首次渲染**时就构造好（`@State` 的初值也在那一刻定格），push 时用的还是那份旧值。
/// 表现就是：第一次进连接正常，退回来再进——库列表一片空白（缓存是进页面之后才有的）。
/// 包一层 LazyView，真正的页面在 push 那一刻才构造，读到的缓存与参数都是最新的。
struct LazyView<Content: View>: View {
    private let build: () -> Content
    init(@ViewBuilder _ build: @escaping () -> Content) { self.build = build }
    var body: some View { build() }
}

/// 卡片中的一行：可选图标 + 标题 + 右侧箭头。几何与系统 List 行一致。
struct CardRow<Destination: View>: View {
    var icon: String? = nil
    let title: String
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: CardListMetrics.iconGap) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundColor(.accentColor)
                        .frame(width: CardListMetrics.iconSlot)
                }
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, CardListMetrics.rowPadding)
            .padding(.vertical, 13)
            .frame(minHeight: CardListMetrics.rowHeight)
        }
        .buttonStyle(CardRowButtonStyle())
    }
}

/// 「常驻搜索框 + 分组卡片」的组合容器：两个列表页（数据库 / 数据表）共用，保证间距一致。
struct SearchableCardList<Content: View>: View {
    @Binding var search: String
    let placeholder: String
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder var rows: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: placeholder, text: $search)
                .padding(.horizontal, CardListMetrics.cardInset)
                .padding(.top, 8)
                .padding(.bottom, CardListMetrics.searchBottomGap)
            ScrollView {
                if isEmpty {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 20)
                } else {
                    CardList { rows() }
                        .padding(.bottom, 24)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
