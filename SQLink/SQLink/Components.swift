import SwiftUI

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

    private let minColWidth: CGFloat = 80
    private let maxColWidth: CGFloat = 160

    var body: some View {
        if columns.isEmpty {
            Text("无结果集").foregroundColor(.secondary).padding()
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    ForEach(0..<rows.count, id: \.self) { ri in
                        dataRow(ri: ri)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .sheet(item: $selectedCell) { cell in
                CellValueSheet(column: columns[safe: cell.col]?.name ?? "", value: cell.value)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns) { c in
                headerCell(c)
            }
        }
    }

    @ViewBuilder
    private func headerCell(_ c: ColumnDef) -> some View {
        let isPK = primaryKey.map { c.name == $0 } ?? false
        let label = (isPK ? "🔑 " : "") + c.name
        Text(label)
            .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: minColWidth * scale, maxWidth: maxColWidth * scale, alignment: .leading)
            .padding(6 * scale)
            .background(isPK ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
    }

    private func dataRow(ri: Int) -> some View {
        let row = rows[ri]
        return HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                // 用安全判断：结果行列数理论上与列定义一致，但列级权限/异常响应下可能偏少，避免越界崩溃
                resultCell(ri: ri, ci: ci, value: ci < row.count ? row[ci] : nil)
            }
        }
    }

    @ViewBuilder
    private func resultCell(ri: Int, ci: Int, value: String?) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        let display = value == nil ? "NULL" : (value! ?? "")
        let text = Text(display)
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(value == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
        let background = isPK ? Color.accentColor.opacity(0.10) : ((ri + ci) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear)

        text
            .frame(minWidth: minColWidth * scale, maxWidth: maxColWidth * scale, alignment: .leading)
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

    private let minColWidth: CGFloat = 80
    private let maxColWidth: CGFloat = 160

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
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(0..<rows.count, id: \.self) { ri in
                    dataRow(ri: ri)
                }
            }
        }
        .frame(height: 320)
        .border(Color.gray.opacity(0.3), width: 0.5)
        .sheet(item: $editTarget) { target in
            CellEditSheet(title: columns[safe: target.ci]?.field ?? "", text: binding(for: target.ri, target.ci))
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                editableHeaderCell(ci)
            }
        }
    }

    @ViewBuilder
    private func editableHeaderCell(_ ci: Int) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        let label = (isPK ? "🔑🔒 " : "") + columns[ci].field
        Text(label)
            .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: minColWidth * scale, maxWidth: maxColWidth * scale, alignment: .leading)
            .padding(6 * scale)
            .background(isPK ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
    }

    private func dataRow(ri: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { ci in
                editableCell(ri: ri, ci: ci)
            }
        }
    }

    @ViewBuilder
    private func editableCell(ri: Int, ci: Int) -> some View {
        let isPK = pkIndex.map { $0 == ci } ?? false
        if isPK {
            pkCell(ri: ri, ci: ci)
        } else {
            valueCell(ri: ri, ci: ci)
        }
    }

    @ViewBuilder
    private func pkCell(ri: Int, ci: Int) -> some View {
        let cell: String? = ci < rows[ri].count ? rows[ri][ci] : nil
        let text = cell ?? "NULL"
        Text(text)
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: minColWidth * scale, maxWidth: maxColWidth * scale, alignment: .leading)
            .padding(6 * scale)
            .background(Color.accentColor.opacity(0.10))
    }

    @ViewBuilder
    private func valueCell(ri: Int, ci: Int) -> some View {
        let background = (ri + ci) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear
        let cell: String? = ci < rows[ri].count ? rows[ri][ci] : nil
        TextField(cell == nil ? "NULL" : "",
                  text: binding(for: ri, ci))
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundColor(cell == nil ? .secondary : .primary)
            .lineLimit(1)
            .frame(minWidth: minColWidth * scale, maxWidth: maxColWidth * scale, alignment: .leading)
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
