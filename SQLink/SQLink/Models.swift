import Foundation

// MARK: - Errors
enum MySQLError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case readError
    case writeError
    case handshakeFailed(String)
    case authFailed(String)
    case serverError(code: Int, message: String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let c, let m): return "MySQL 错误 \(c)：\(m)"
        case .connectionFailed(let m): return "连接失败：\(m)"
        case .authFailed(let m): return "认证失败：\(m)"
        case .connectionClosed: return "连接已被服务器关闭"
        case .handshakeFailed(let m): return "握手失败：\(m)"
        case .readError: return "读取数据失败"
        case .writeError: return "写入数据失败"
        case .protocolError(let m): return "协议错误：\(m)"
        }
    }

    /// 连接已断开（socket 写失败 / 被服务器关闭），可尝试自动重连。
    var isDeadConnection: Bool {
        switch self {
        case .writeError, .connectionClosed: return true
        default: return false
        }
    }
}

// MARK: - Connection profile (password lives in Keychain, never here)
struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var user: String
    var database: String
    var useTLS: Bool
    var trustSelfSigned: Bool

    init(id: UUID = UUID(), name: String = "", host: String = "", port: Int = 3306,
         user: String = "root", database: String = "", useTLS: Bool = false, trustSelfSigned: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.useTLS = useTLS
        self.trustSelfSigned = trustSelfSigned
    }
}

// MARK: - Query result model
struct ColumnDef: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: UInt8
    var typeName: String { MySQLDataType.name(for: type) }
}

struct ColumnInfo: Identifiable {
    let id = UUID()
    let field: String
    let type: String
    let null: String
    let key: String
    let `default`: String
    let extra: String
}

enum QueryResult {
    case ok(affectedRows: Int)
    case result(columns: [ColumnDef], rows: [[String?]])
}

// MARK: - Filter & sort helpers
enum FilterOperator: String, CaseIterable, Codable, Identifiable {
    case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
    case contains, notContains, startsWith, notStartsWith, endsWith, notEndsWith
    case isNull, isNotNull, isEmpty, isNotEmpty, inList, notInList, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equal: return "等于"
        case .notEqual: return "不等于"
        case .lessThan: return "小于"
        case .lessOrEqual: return "小于等于"
        case .greaterThan: return "大于"
        case .greaterOrEqual: return "大于等于"
        case .contains: return "包含"
        case .notContains: return "不包含"
        case .startsWith: return "开始以"
        case .notStartsWith: return "不开始于"
        case .endsWith: return "结束于"
        case .notEndsWith: return "不结束于"
        case .isNull: return "是 null"
        case .isNotNull: return "不是 null"
        case .isEmpty: return "是空的"
        case .isNotEmpty: return "不是空的"
        case .inList: return "在列表"
        case .notInList: return "不在列表"
        case .custom: return "自定义"
        }
    }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty:
            return false
        default:
            return true
        }
    }
}

enum SortDirection: String, CaseIterable, Codable, Identifiable {
    case asc, desc
    var id: String { rawValue }
    var label: String { self == .asc ? "升序" : "降序" }
}

enum FilterLogic: String, CaseIterable, Identifiable, Codable, Hashable {
    case and = "AND"
    case or = "OR"
    var id: String { rawValue }
    var label: String { rawValue }
}

struct FilterCondition: Identifiable, Codable, Hashable {
    let id = UUID()
    var field: String = ""
    var op: FilterOperator = .contains
    var value: String = ""
    var enabled: Bool = true
    /// 本条条件与前一条条件之间的逻辑关系（AND/OR）。第一条为 nil。
    var logic: FilterLogic? = nil
}

// MARK: - MySQL data type names (subset, enough for display)
enum MySQLDataType {
    static func name(for type: UInt8) -> String {
        switch type {
        case 0x00: return "DECIMAL"
        case 0x01: return "TINY"
        case 0x02: return "SHORT"
        case 0x03: return "LONG"
        case 0x04: return "FLOAT"
        case 0x05: return "DOUBLE"
        case 0x06: return "NULL"
        case 0x07: return "TIMESTAMP"
        case 0x08: return "LONGLONG"
        case 0x09: return "INT24"
        case 0x0A: return "DATE"
        case 0x0B: return "TIME"
        case 0x0C: return "DATETIME"
        case 0x0D: return "YEAR"
        case 0x0E: return "NEWDATE"
        case 0x0F: return "VARCHAR"
        case 0x10: return "BIT"
        case 0xF6: return "NEWDECIMAL"
        case 0xF7: return "ENUM"
        case 0xF8: return "SET"
        case 0xF9: return "TINY_BLOB"
        case 0xFA: return "MEDIUM_BLOB"
        case 0xFB: return "LONG_BLOB"
        case 0xFC: return "BLOB"
        case 0xFD: return "VAR_STRING"
        case 0xFE: return "STRING"
        case 0xFF: return "GEOMETRY"
        default: return "UNKNOWN(\(type))"
        }
    }
}

// MARK: - App-wide settings (persisted in UserDefaults)
enum ThemeMode: Int, CaseIterable, Identifiable, Codable {
    case light = 0
    case dark = 1
    var id: Int { rawValue }
    var label: String { self == .light ? "浅色" : "深色" }
}

/// 全局设置：主题、自动保存 SQL、默认每页条数、会员状态、账号。
/// 用 @Published + 手动落盘 UserDefaults，避免在 ObservableObject 内使用 @AppStorage
/// 不触发 objectWillChange 的经典坑。
final class AppSettings: ObservableObject {
    @Published var theme: ThemeMode {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "sqlink.theme") }
    }
    @Published var autoSaveSQL: Bool {
        didSet { UserDefaults.standard.set(autoSaveSQL, forKey: "sqlink.autoSaveSQL") }
    }
    @Published var pageSize: Int {
        didSet { UserDefaults.standard.set(pageSize, forKey: "sqlink.pageSize") }
    }
    @Published var isPro: Bool {
        didSet { UserDefaults.standard.set(isPro, forKey: "sqlink.isPro") }
    }
    @Published var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "sqlink.apiBaseURL") }
    }
    @Published var authToken: String {
        didSet { UserDefaults.standard.set(authToken, forKey: "sqlink.authToken") }
    }
    @Published var authEmail: String {
        didSet { UserDefaults.standard.set(authEmail, forKey: "sqlink.authEmail") }
    }
    @Published var avatarURL: String {
        didSet { UserDefaults.standard.set(avatarURL, forKey: "sqlink.avatarURL") }
    }
    @Published var guestMode: Bool {
        didSet { UserDefaults.standard.set(guestMode, forKey: "sqlink.guestMode") }
    }
    /// 公共配置：免费额度 + 会员价格。由后端 /api/public/config 返回，本地缓存。
    @Published var plan: PlanConfig {
        didSet {
            if let d = try? JSONEncoder().encode(plan) {
                UserDefaults.standard.set(d, forKey: "sqlink.plan")
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        self.theme = ThemeMode(rawValue: d.integer(forKey: "sqlink.theme")) ?? .light
        self.autoSaveSQL = (d.object(forKey: "sqlink.autoSaveSQL") as? Bool) ?? true
        self.pageSize = (d.object(forKey: "sqlink.pageSize") as? Int) ?? 100
        self.isPro = (d.object(forKey: "sqlink.isPro") as? Bool) ?? false
        self.apiBaseURL = d.string(forKey: "sqlink.apiBaseURL") ?? "https://sqlink-api.cute6696.cn"
        self.authToken = d.string(forKey: "sqlink.authToken") ?? ""
        self.authEmail = d.string(forKey: "sqlink.authEmail") ?? ""
        self.avatarURL = d.string(forKey: "sqlink.avatarURL") ?? ""
        self.guestMode = (d.object(forKey: "sqlink.guestMode") as? Bool) ?? false
        if let pd = d.data(forKey: "sqlink.plan"),
           let p = try? JSONDecoder().decode(PlanConfig.self, from: pd) {
            self.plan = p
        } else {
            self.plan = .default
        }
    }

    var isLoggedIn: Bool { !authToken.isEmpty || guestMode }

    func logout() {
        authToken = ""
        authEmail = ""
        avatarURL = ""
        guestMode = false
        isPro = false
    }

    func enterGuestMode() {
        guestMode = true
        authToken = ""
        authEmail = ""
        isPro = false
    }

    func applyMembership(_ email: String, token: String, isPro: Bool) {
        self.authEmail = email
        self.authToken = token
        self.guestMode = false
        self.isPro = isPro
    }

    /// 拉取后端公共配置（免费额度 + 价格），失败则保留本地缓存。
    func refreshPlan() async {
        do {
            let p = try await AuthService.shared.fetchPublicConfig(baseURL: apiBaseURL)
            await MainActor.run { self.plan = p }
        } catch {
            print("刷新公共配置失败：\(error.localizedDescription)")
        }
    }
}

/// 后端返回的公开配置（字段与 /api/public/config 的 snake_case 对应）。
struct PlanConfig: Codable {
    var freeExportLimit: Int
    var freeViewLimit: Int
    var proPriceYearly: Int
    var proPriceLifetime: Int
    var currency: String

    static let `default` = PlanConfig(
        freeExportLimit: 100,
        freeViewLimit: 100,
        proPriceYearly: 68,
        proPriceLifetime: 98,
        currency: "¥"
    )
}
