import Foundation
import Security

/// iCloud Keychain 同步封装。
///
/// 用途：把登录态与会员凭证同步到 iCloud 钥匙串（同 Apple ID 设备自动同步），
/// 解决「卸载 App / 换手机后 UserDefaults 清空导致会员失效、需重新登录」的问题。
///
/// 关键点：
/// - 使用 `kSecAttrSynchronizable = true`，数据通过 iCloud 在用户同一 Apple ID 的
///   设备间自动同步。用户无需手动导出任何可复制文本，凭证不会被截图/转发扩散。
/// - 前提：用户已在 iOS「设置 → Apple ID → iCloud → 钥匙串」中开启 iCloud 钥匙串。
///   未开启时所有写入静默失败，退化为仅本机（不影响主流程）。
/// - 所有写入均容错：iCloud 不可用 / 设备不支持时返回 false，调用方忽略即可。
enum KeychainSync {
    private static let service = "com.sqllink.app.credentials"
    private static let synchronizable: Any = true

    static let authTokenKey = "authToken"
    static let authEmailKey = "authEmail"
    static let nicknameKey = "nickname"
    static let proExpiresAtKey = "proExpiresAt"
    static let isProKey = "isPro"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    /// 写入一条凭证。value 为空时改为删除该项（避免残留空串）。
    /// 返回是否成功（iCloud 不可用时为 false，调用方可忽略）。
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { delete(account); return true }
        let query = baseQuery(account)
        var addQuery = query
        addQuery[kSecValueData as String] = Data(value.utf8)
        // 先删后加，等价于 upsert，避免重复项导致读取歧义。
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取一条凭证。不存在 / 不可用时返回 nil。
    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除一条凭证。
    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// 清空本 service 下所有同步项（用于退出登录）。
    static func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable
        ]
        SecItemDelete(query as CFDictionary)
    }
}
