import Foundation

/// SQLink 账号后端 API 封装
enum AuthError: Error, LocalizedError {
    case network(Error)
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .network(let e): return "网络错误：\(e.localizedDescription)"
        case .invalidResponse: return "服务器返回异常"
        case .message(let m): return m
        }
    }
}

struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?
}

struct AuthTokenData: Decodable {
    let token: String?
    let email: String?
    let isPro: Bool?
    let code: String?
    /// 登录 / 注册响应里的头像 URL（后端 app.js 的 login 返回 `avatar: user.avatar || ''`）。
    /// 此前这里漏了解码，导致「重装后登录成功却拿不到头像」——服务端明明给了，客户端把它丢了。
    let avatar: String?
}

/// 激活码兑换返回：仅需会员判定结果（会员为本地永久判定，无到期时间 / 类型 / 过期等冗余字段）。
struct MembershipData: Decodable {
    let isPro: Bool
}

/// GET /api/user/membership 返回的用户资料（需登录）。
/// 仅用于补齐本地缺失的头像 —— 会员状态仍按「本地永久判定」处理，不用它的 isPro 覆盖本地值。
struct MembershipInfoData: Decodable {
    let email: String?
    let avatar: String?
}

struct AvatarData: Decodable {
    let url: String?
}

/// 反馈提交成功时后端不返回业务数据，仅 code/message。
struct EmptyData: Decodable {}

final class AuthService {
    static let shared = AuthService()
    private init() {}

    private func url(base: String, path: String) -> URL? {
        var s = base
        if s.hasSuffix("/") { s.removeLast() }
        // 接口地址可能被改成非法值，这里安全返回 nil，避免强解包崩溃
        return URL(string: "\(s)\(path)")
    }

    private func request<T: Decodable>(baseURL: String, path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> APIResponse<T> {
        guard let apiURL = url(base: baseURL, path: path) else {
            throw AuthError.message("接口地址无效，请检查服务端地址配置")
        }
        var req = URLRequest(url: apiURL)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let httpResp = response as? HTTPURLResponse
        // 滑动续期：后端在 token 临近过期时会通过 x-auth-token 响应头返回新签发的 30 天 token，
        // 前端据此刷新本地 token，活跃用户不会在 30 天到期时突然掉线。
        if let newToken = httpResp?.value(forHTTPHeaderField: "x-auth-token"), !newToken.isEmpty {
            await MainActor.run { AppSettings.shared.authToken = newToken }
        }
        // token 失效（过期 / 被服务端拒绝 / 改过密码）：清除本地登录态，回到登录页。
        // 这样「90 天绝对上限」触发或 token 被吊销时，用户会被平滑引导重新登录，
        // 而不是停留在「已登录但所有请求都 401」的卡死状态。
        if httpResp?.statusCode == 401 {
            await MainActor.run { AppSettings.shared.logout() }
        }
        // 404：Express 返回的是一页 HTML（"Cannot POST /xxx"），不是 JSON。
        // 直接解码只会抛出英文 DecodingError，用户看到 "The data couldn't be read…" 无从下手；
        // 单独识别出来，明确告知「后端未更新 / 接口不存在」。
        if httpResp?.statusCode == 404 {
            throw AuthError.message("服务端没有该接口（后端可能尚未更新，请先部署最新后端）")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(APIResponse<T>.self, from: data)
        } catch {
            // 非 JSON 响应或字段不匹配：统一转成中文提示，不把 DecodingError 抛到界面上。
            throw AuthError.invalidResponse
        }
    }

    private func require<T>(_ resp: APIResponse<T>, extract: (T) -> Bool) async throws {
        if resp.code == 200, let d = resp.data, extract(d) { return }
        throw AuthError.message(resp.message)
    }

    func sendRegisterCode(baseURL: String, email: String) async throws -> String? {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/register/code", body: ["email": email])
        if resp.code == 200, let code = resp.data?.code, !code.isEmpty {
            return code
        }
        if resp.code != 200 { throw AuthError.message(resp.message) }
        return nil
    }

    func register(baseURL: String, email: String, code: String, password: String) async throws -> (token: String, email: String, isPro: Bool, avatar: String) {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/register", body: ["email": email, "code": code, "password": password])
        guard resp.code == 200, let d = resp.data, let token = d.token, let email = d.email else {
            throw AuthError.message(resp.message)
        }
        return (token, email, d.isPro ?? false, d.avatar ?? "")
    }

    func login(baseURL: String, email: String, password: String) async throws -> (token: String, email: String, isPro: Bool, avatar: String) {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/login", body: ["email": email, "password": password])
        guard resp.code == 200, let d = resp.data, let token = d.token, let email = d.email else {
            throw AuthError.message(resp.message)
        }
        return (token, email, d.isPro ?? false, d.avatar ?? "")
    }

    func sendResetCode(baseURL: String, email: String) async throws -> String? {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/forgot-password/code", body: ["email": email])
        if resp.code == 200, let code = resp.data?.code, !code.isEmpty {
            return code
        }
        if resp.code != 200 { throw AuthError.message(resp.message) }
        return nil
    }

    func resetPassword(baseURL: String, email: String, code: String, password: String) async throws {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/reset-password", body: ["email": email, "code": code, "password": password])
        if resp.code != 200 { throw AuthError.message(resp.message) }
    }

    /// 拉取当前登录账号的资料（需登录）。用于重装 / 冷启动后补齐本地缺失的头像 URL。
    func fetchMembership(baseURL: String, token: String) async throws -> MembershipInfoData {
        let resp: APIResponse<MembershipInfoData> = try await request(baseURL: baseURL, path: "/api/user/membership", token: token)
        guard resp.code == 200, let d = resp.data else { throw AuthError.message(resp.message) }
        return d
    }

    /// 修改密码（需登录）：先校验当前密码，通过后重置为新密码。
    /// 后端对应 POST /api/auth/change-password，要求 Bearer token + 旧密码 ——
    /// 「只有登录成功之后才可以修改密码」由服务端强制，客户端无法绕过。
    /// 修改成功后服务端会让所有旧 token 立即失效，因此必须重新登录。
    func changePassword(baseURL: String, token: String, oldPassword: String, newPassword: String) async throws {
        let resp: APIResponse<EmptyData> = try await request(
            baseURL: baseURL,
            path: "/api/auth/change-password",
            token: token,
            body: ["oldPassword": oldPassword, "newPassword": newPassword]
        )
        if resp.code != 200 { throw AuthError.message(resp.message) }
    }

    func fetchPublicConfig(baseURL: String) async throws -> PlanConfig {
        let resp: APIResponse<PlanConfig> = try await request(baseURL: baseURL, path: "/api/public/config")
        guard resp.code == 200, let data = resp.data else { throw AuthError.message(resp.message) }
        return data
    }

    /// 上传头像：imageBase64 为裸 base64 字符串（不含 data URI 前缀），ext 为扩展名（jpg/png/webp）。
    func uploadAvatar(baseURL: String, token: String, imageBase64: String, ext: String) async throws -> String {
        let resp: APIResponse<AvatarData> = try await request(baseURL: baseURL, path: "/api/user/avatar", token: token, body: ["image": imageBase64, "ext": ext])
        guard resp.code == 200, let url = resp.data?.url, !url.isEmpty else {
            throw AuthError.message(resp.message)
        }
        return url
    }

    /// 激活码兑换：凭码自助开通永久会员，返回最新会员状态。
    func redeemActivation(baseURL: String, token: String, code: String) async throws -> MembershipData {
        let resp: APIResponse<MembershipData> = try await request(baseURL: baseURL, path: "/api/activation/redeem", token: token, body: ["code": code])
        guard resp.code == 200, let data = resp.data else { throw AuthError.message(resp.message) }
        return data
    }

    /// 提交意见反馈：content 必填，contact 选填；后端按账号 + IP 双重限流防爆破。
    func submitFeedback(baseURL: String, token: String, content: String, contact: String) async throws {
        let resp: APIResponse<EmptyData> = try await request(baseURL: baseURL, path: "/api/feedback", token: token, body: ["content": content, "contact": contact])
        if resp.code != 200 { throw AuthError.message(resp.message) }
    }

    /// 注销账号（App Store 上架要求的账号删除能力）：凭当前 token 删除账号及云端数据。
    /// 后端对应 POST /api/user/delete（删除 feedback → 删七牛头像 → 删 users）。
    func deleteAccount(baseURL: String, token: String) async throws {
        let resp: APIResponse<EmptyData> = try await request(baseURL: baseURL, path: "/api/user/delete", token: token, body: [:])
        if resp.code != 200 { throw AuthError.message(resp.message) }
    }
}
