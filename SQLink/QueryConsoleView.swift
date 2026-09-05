import SwiftUI

struct QueryConsoleView: View {
    let connection: MySQLConnection
    let db: String?
    @State private var sql = ""
    @State private var columns: [ColumnDef] = []
    @State private var rows: [[String?]] = []
    @State private var message: String?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(db == nil ? "未选择数据库（请使用 `库名`.`表名` 或先 USE）" : "当前数据库：\(db!)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 8)

            TextEditor(text: $sql)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                .padding(8)

            HStack {
                Button { Task { await run() } } label: {
                    if running { ProgressView() } else { Label("运行", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
                Spacer()
                if let message = message {
                    Text(message).font(.footnote).foregroundColor(message.contains("返回") ? .primary : .red)
                }
            }.padding(.horizontal, 12)

            Divider().padding(.vertical, 6)

            if columns.isEmpty && rows.isEmpty {
                Spacer()
                Text("运行 SQL 后在此显示结果").foregroundColor(.secondary)
                Spacer()
            } else {
                ResultGridView(columns: columns, rows: rows)
                    .padding(.horizontal, 8)
                Spacer()
            }
        }
        .navigationTitle("查询控制台")
        .navigationBarTitleDisplayMode(.inline)
    }

    func run() async {
        running = true
        let stmts = sql.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !stmts.isEmpty else {
            await MainActor.run { message = "请输入 SQL" }
            await MainActor.run { running = false }
            return
        }
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
            }
        } catch {
            let msg = "错误：\(error.localizedDescription)"
            await MainActor.run { self.message = msg }
        }
        await MainActor.run { running = false }
    }
}
