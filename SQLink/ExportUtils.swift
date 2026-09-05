import Foundation
import SwiftUI
import UIKit

/// 导出格式。CSV 适合 Excel / 数据分析；SQL 生成 INSERT 语句方便迁移。
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, sql
    var id: String { rawValue }
    var label: String { self == .csv ? "CSV" : "SQL" }
}

/// 会员状态单一数据源。
/// 当前会员体系（邮箱登录 + 内购）尚未接入，默认返回 true，使导出等功能在当前构建中可用。
/// TODO: 接入会员后改为读取后端返回的 membership 状态（或本地收据校验结果）。
enum AppConfig {
    static var isPro: Bool {
        (UserDefaults.standard.object(forKey: "sqlink_isPro") as? Bool) ?? true
    }
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
                let v = i < row.count ? row[i] : nil
                if let s = v, !s.isEmpty {
                    return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
                }
                return "NULL"
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
}
