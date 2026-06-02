import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Supabase Auth session. `expiresAt` is unix seconds (Supabase `expires_at`).
public struct Session: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Double
    public let tokenType: String?

    public var expiryDate: Date { Date(timeIntervalSince1970: expiresAt) }

    /// True if expired (or within `leeway` of expiring) — used to refresh proactively.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway).timeIntervalSince1970 >= expiresAt
    }
}

/// Supabase Auth client: sign up / sign in / refresh, with a `accessToken()` that auto-refreshes.
/// Pair with `NutritionAPI` by passing `{ try await auth.accessToken() }` as its tokenProvider.
/// An actor so the cached session is mutated safely across concurrent calls.
public actor NutritionAuth {
    public enum AuthError: Error, Sendable {
        case http(Int, String)
        case emailConfirmationRequired
        case notAuthenticated
    }

    let baseURL: URL
    let apiKey: String
    let urlSession: URLSession
    private let decoder = JSONDecoder.supabase()   // convertFromSnakeCase; Session has no Date fields
    private var current: Session?

    public init(baseURL: URL, apiKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    public var session: Session? { current }

    /// Sign up. Throws `.emailConfirmationRequired` when the project requires email confirmation
    /// (signup succeeds but returns no session until the user confirms).
    @discardableResult
    public func signUp(email: String, password: String) async throws -> Session {
        let data = try await post("auth/v1/signup", body: ["email": email, "password": password])
        guard let s = try? decoder.decode(Session.self, from: data) else {
            throw AuthError.emailConfirmationRequired
        }
        current = s
        return s
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Session {
        let data = try await post("auth/v1/token",
                                  query: [.init(name: "grant_type", value: "password")],
                                  body: ["email": email, "password": password])
        let s = try decoder.decode(Session.self, from: data)
        current = s
        return s
    }

    @discardableResult
    public func refresh() async throws -> Session {
        guard let token = current?.refreshToken else { throw AuthError.notAuthenticated }
        let data = try await post("auth/v1/token",
                                  query: [.init(name: "grant_type", value: "refresh_token")],
                                  body: ["refresh_token": token])
        let s = try decoder.decode(Session.self, from: data)
        current = s
        return s
    }

    public func signOut() { current = nil }

    /// A valid access token, refreshing if expired/near expiry. Use as NutritionAPI's tokenProvider.
    public func accessToken() async throws -> String {
        guard let s = current else { throw AuthError.notAuthenticated }
        return s.isExpired() ? try await refresh().accessToken : s.accessToken
    }

    private func post(_ path: String, query: [URLQueryItem] = [], body: [String: String]) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AuthError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}
