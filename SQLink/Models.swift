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

enum FilterLogic: String, CaseIterable, Identifiable {
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
