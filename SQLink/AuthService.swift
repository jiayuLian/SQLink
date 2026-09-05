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
}

struct MembershipData: Decodable {
    let email: String?
    let avatar: String?
    let isPro: Bool
    let expiresAt: String?
    let remark: String?
}

struct AvatarData: Decodable {
    let url: String?
}

final class AuthService {
    static let shared = AuthService()
    private init() {}

    private func url(base: String, path: String) -> URL {
        var s = base
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: "\(s)\(path)")!
    }

    private func request<T: Decodable>(baseURL: String, path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> APIResponse<T> {
        var req = URLRequest(url: url(base: baseURL, path: path))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(APIResponse<T>.self, from: data)
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

    func register(baseURL: String, email: String, code: String, password: String) async throws -> (token: String, email: String, isPro: Bool) {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/register", body: ["email": email, "code": code, "password": password])
        guard resp.code == 200, let d = resp.data, let token = d.token, let email = d.email else {
            throw AuthError.message(resp.message)
        }
        return (token, email, d.isPro ?? false)
    }

    func login(baseURL: String, email: String, password: String) async throws -> (token: String, email: String, isPro: Bool) {
        let resp: APIResponse<AuthTokenData> = try await request(baseURL: baseURL, path: "/api/auth/login", body: ["email": email, "password": password])
        guard resp.code == 200, let d = resp.data, let token = d.token, let email = d.email else {
            throw AuthError.message(resp.message)
        }
        return (token, email, d.isPro ?? false)
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

    func fetchMembership(baseURL: String, token: String) async throws -> MembershipData {
        let resp: APIResponse<MembershipData> = try await request(baseURL: baseURL, path: "/api/user/membership", token: token)
        guard resp.code == 200, let data = resp.data else { throw AuthError.message(resp.message) }
        return data
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
}
