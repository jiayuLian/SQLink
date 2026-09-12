import Foundation
import SwiftUI
import UIKit

/// 导出格式。CSV 适合 Excel / 数据分析；SQL 生成 INSERT 语句方便迁移。
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, sql
    var id: String { rawValue }
    var label: String { self == .csv ? "CSV" : "SQL" }
}

/// 导出进度状态（引用类型，便于在后台 Task 中安全更新 UI）。
final class ExportProgressModel: ObservableObject {
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var message: String?
}

/// 结果集导出工具：生成 CSV / SQL 文本并写入临时文件。
struct ExportUtils {
    /// 生成 CSV 文本（带标准引号转义）。
    static func buildCSV(columnNames: [String], rows: [[String?]]) -> String {
        func esc(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var out: [String] = []
        out.append(columnNames.map { esc($0) }.joined(separator: ","))
        for row in rows {
            let cells = columnNames.indices.map { i -> String in
                let v = i < row.count ? row[i] : nil
                return esc(v ?? "")
            }
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n")
    }

    /// 生成 INSERT 语句（NULL 写 NULL，其余按字符串转义）。
    static func buildSQL(insertInto table: String, columnNames: [String], rows: [[String?]]) -> String {
        guard !columnNames.isEmpty else { return "" }
        let safeTable = table.replacingOccurrences(of: "`", with: "``")
        let cols = columnNames.map { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }.joined(separator: ", ")
        var statements: [String] = []
        for row in rows {
            let vals = columnNames.indices.map { i -> String in
                // NULL 与空字符串必须区分：NULL 写 NULL，空串写 ''，否则导出再导入会改变数据语义
                return sqlValue(i < row.count ? row[i] : nil)
            }
            statements.append("INSERT INTO `\(safeTable)` (\(cols)) VALUES (\(vals.joined(separator: ", ")));")
        }
        return statements.joined(separator: "\n")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    /// CSV 单元格转义（与 buildCSV 一致）。
    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func sqlValue(_ v: String?) -> String {
        // 仅 nil 视为 NULL；空字符串要写成 ''，与 CSV 路径保持一致
        guard let s = v else { return "NULL" }
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 流式导出整张表（按筛选/排序）。
    ///
    /// 关键优化（应对大数据量）：
    /// - 分块拉取（每块 chunkSize 行），**边拉边增量写文件**，绝不把全部行同时放进内存，避免 OOM；
    /// - 生成 / 写文件在后台线程执行（调用方应放在 `Task.detached` 里），不冻结 UI；
    /// - `maxRows` 为 nil 表示无限制（会员）；非 nil 时只导出前 maxRows 行（免费版额度）；
    /// - `onProgress` 回调 `0...1` 的进度与已导出行数，便于 UI 展示。
    ///
    /// - Returns: 生成的临时文件 URL。
    @discardableResult
    static func exportTableStreaming(connection: MySQLConnection,
                                     db: String, table: String,
                                     whereClause: String?, orderBy: String?,
                                     format: ExportFormat,
                                     maxRows: Int? = nil,
                                     chunkSize: Int = 500,
                                     onProgress: @escaping (Double, Int) -> Void) async throws -> URL {
        let safeTable = table.replacingOccurrences(of: "`", with: "``")
        let ts = ExportUtils.timestamp()
        let fileName = format == .csv ? "\(safeTable)_\(ts).csv" : "\(safeTable)_\(ts).sql"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let total = try await withReconnect(connection) { try await connection.countRows(db: db, table: table, whereClause: whereClause) }
        let limit = maxRows ?? total
        guard limit > 0 else {
            // 空结果也生成一个空文件，保证分享面板能弹出
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return url
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var fetched = 0
        var offset = 0
        var wroteHeader = false
        while fetched < limit, offset < total {
            let take = min(chunkSize, limit - fetched, max(1, total - offset))
            let r = try await withReconnect(connection) { try await connection.fetchRows(db: db, table: table, limit: take, offset: offset, whereClause: whereClause, orderBy: orderBy) }
            guard case .result(let cols, let rows) = r else { break }
            if cols.isEmpty { break }
            if format == .csv {
                if !wroteHeader {
                    let header = cols.map { csvEscape($0.name) }.joined(separator: ",")
                    handle.write(header.data(using: .utf8)!)
                    handle.write("\n".data(using: .utf8)!)
                    wroteHeader = true
                }
                var buf = ""
                for row in rows {
                    let cells = cols.indices.map { i -> String in
                        csvEscape(i < row.count ? (row[i] ?? "") : "")
                    }
                    buf += cells.joined(separator: ",") + "\n"
                }
                handle.write(buf.data(using: .utf8)!)
            } else {
                let colsSql = cols.map { "`\($0.name.replacingOccurrences(of: "`", with: "``"))`" }.joined(separator: ", ")
                var buf = ""
                for row in rows {
                    let vals = cols.indices.map { i -> String in
                        sqlValue(i < row.count ? row[i] : nil)
                    }
                    buf += "INSERT INTO `\(safeTable)` (\(colsSql)) VALUES (\(vals.joined(separator: ", ")));\n"
                }
                handle.write(buf.data(using: .utf8)!)
            }
            fetched += rows.count
            offset += rows.count
            onProgress(Double(fetched) / Double(max(1, min(limit, total))), fetched)
            if rows.isEmpty { break }
        }
        return url
    }

    /// 写入临时目录，返回文件 URL（失败返回 nil）。
    static func writeTempFile(name: String, content: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// 系统分享面板，用于把导出的文件保存到「文件」App / AirDrop / 其他 App。
///
/// 注意：不要把这个 `UIActivityViewController` 包进 SwiftUI 的 `.sheet` 里弹出——
/// 那样在 iOS 15 上首次弹出会是空白页（第二次才正常），是个已知坑。
/// 这里改为直接 present 到最顶层 ViewController，绕开该问题。
extension UIApplication {
    /// 找到当前最上层的 ViewController（用于直接 present 分享面板）。
    func topViewController() -> UIViewController? {
        let scene = connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? connectedScenes.first as? UIWindowScene
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

extension ExportUtils {
    /// 直接弹出系统分享面板（保存文件 / AirDrop / 其他 App）。
    static func shareFile(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let top = UIApplication.shared.topViewController() else { return }
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }

    /// 直接弹出系统分享面板，分享一个链接（如 App 下载地址）。
    /// 若设备已安装微信 / QQ，系统分享面板会列出它们，用户可一键分享到微信、朋友圈、QQ。
    static func shareLink(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let top = UIApplication.shared.topViewController() else { return }
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}
