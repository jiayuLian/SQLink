import SwiftUI

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

/// Connection row shown in the main list.
struct ConnectionRow: View {
    let profile: ConnectionProfile
    var onEdit: (() -> Void)? = nil
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
            if let onEdit = onEdit {
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.accentColor)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Clean, scrollable result grid (Navicat-style).
struct ResultGridView: View {
    let columns: [ColumnDef]
    let rows: [[String?]]
    var scale: CGFloat = 1.0

    var body: some View {
        if columns.isEmpty {
            Text("无结果集").foregroundColor(.secondary).padding()
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns) { c in
                            Text(c.name)
                                .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
                                .frame(minWidth: 120 * scale, alignment: .leading)
                                .padding(6 * scale)
                                .background(Color.gray.opacity(0.18))
                        }
                    }
                    ForEach(0..<rows.count, id: \.self) { ri in
                        let row = rows[ri]
                        HStack(spacing: 0) {
                            ForEach(0..<columns.count, id: \.self) { j in
                                let v = row[safe: j]
                                let display = v == nil ? "NULL" : (v! ?? "")
                                Text(display)
                                    .font(.system(size: 12 * scale, design: .monospaced))
                                    .foregroundColor(v == nil ? .secondary : .primary)
                                    .frame(minWidth: 120 * scale, alignment: .leading)
                                    .padding(6 * scale)
                                    .background((ri + j) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear)
                                    .lineLimit(4)
                                    .contextMenu {
                                        if v != nil {
                                            Button { UIPasteboard.general.string = v! ?? "" }
                                                label: { Label("复制值", systemImage: "doc.on.doc") }
                                        } else {
                                            Button { } label: { Label("NULL（无值）", systemImage: "nosign") }
                                                .disabled(true)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Inline-editable result grid for TableDetailView editing mode.
struct EditableGridView: View {
    let columns: [ColumnInfo]
    @Binding var rows: [[String?]]
    let originalRows: [[String?]]
    var scale: CGFloat = 1.0
    let onChange: () -> Void

    private func binding(for ri: Int, _ ci: Int) -> Binding<String> {
        Binding(
            get: { rows[ri][ci] ?? "" },
            set: { new in
                if new.isEmpty && originalRows[ri][ci] == nil {
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
                HStack(spacing: 0) {
                    ForEach(0..<columns.count, id: \.self) { ci in
                        Text(columns[ci].field)
                            .font(.system(size: 13 * scale, weight: .bold, design: .monospaced))
                            .frame(minWidth: 120 * scale, alignment: .leading)
                            .padding(6 * scale)
                            .background(Color.gray.opacity(0.18))
                    }
                }
                ForEach(0..<rows.count, id: \.self) { ri in
                    HStack(spacing: 0) {
                        ForEach(0..<columns.count, id: \.self) { ci in
                            TextField(rows[ri][ci] == nil ? "NULL" : "",
                                      text: binding(for: ri, ci))
                                .font(.system(size: 12 * scale, design: .monospaced))
                                .foregroundColor(rows[ri][ci] == nil ? .secondary : .primary)
                                .frame(minWidth: 120 * scale, alignment: .leading)
                                .padding(6 * scale)
                                .background((ri + ci) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear)
                        }
                    }
                }
            }
        }
        .frame(height: 320)
        .border(Color.gray.opacity(0.3), width: 0.5)
    }
}
