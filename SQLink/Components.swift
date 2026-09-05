import SwiftUI

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

/// Connection row shown in the main list.
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

/// Clean, scrollable result grid (Navicat-style).
struct ResultGridView: View {
    let columns: [ColumnDef]
    let rows: [[String?]]

    var body: some View {
        if columns.isEmpty {
            Text("无结果集").foregroundColor(.secondary).padding()
        } else {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns) { c in
                            Text(c.name)
                                .font(.system(.subheadline, design: .monospaced).bold())
                                .frame(minWidth: 120, alignment: .leading)
                                .padding(6)
                                .background(Color.gray.opacity(0.18))
                        }
                    }
                    ForEach(0..<rows.count, id: \.self) { ri in
                        let row = rows[ri]
                        HStack(spacing: 0) {
                            ForEach(0..<columns.count, id: \.self) { j in
                                let v = row[safe: j]
                                Text(v == nil ? "NULL" : (v! ?? ""))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(v == nil ? .secondary : .primary)
                                    .frame(minWidth: 120, alignment: .leading)
                                    .padding(6)
                                    .background((ri + j) % 2 == 0 ? Color.gray.opacity(0.04) : Color.clear)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
            .border(Color.gray.opacity(0.3), width: 0.5)
        }
    }
}
