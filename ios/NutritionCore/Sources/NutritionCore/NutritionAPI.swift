import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the Nutrition App backend. Every call runs under the user's Supabase JWT
/// (supplied by `tokenProvider`), so Postgres RLS confines it to that user's rows — the
/// same isolation the MCP server relies on. This is the SwiftData → API re-point.
public struct NutritionAPI {
    public enum APIError: Error, Sendable {
        case http(Int, String)
        case decoding(String)
        case emptyResponse
        case badToken
    }

    let baseURL: URL                                   // https://<ref>.supabase.co
    let apiKey: String                                 // publishable key (apikey header)
    let tokenProvider: @Sendable () async throws -> String
    let session: URLSession
    let decoder = JSONDecoder.supabase()
    let encoder = JSONEncoder.supabase()

    public init(baseURL: URL,
                apiKey: String,
                session: URLSession = .shared,
                tokenProvider: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Reads

    public func today() async throws -> DaySummary {
        try await rpc("nutrition_day", body: Data("{}".utf8))
    }

    public func day(_ date: String) async throws -> DaySummary {
        struct R: Encodable { let pDate: String }
        return try await rpc("nutrition_day", body: try encoder.encode(R(pDate: date)))
    }

    public func range(start: String, end: String) async throws -> RangeSummary {
        struct R: Encodable { let pStart: String; let pEnd: String }
        return try await rpc("nutrition_range", body: try encoder.encode(R(pStart: start, pEnd: end)))
    }

    public func targets() async throws -> NutritionTargets? {
        let req = try await makeRequest("GET", "rest/v1/targets", query: [
            .init(name: "select", value: "calories,protein_g,carbs_g,fat_g"),
            .init(name: "order", value: "effective_from.desc"),
            .init(name: "limit", value: "1"),
        ])
        return try await send(req, as: [NutritionTargets].self).first
    }

    public func searchEntries(query: String, start: String? = nil, end: String? = nil, limit: Int = 25) async throws -> [NutritionEntry] {
        var items: [URLQueryItem] = [
            .init(name: "select", value: "*"),
            .init(name: "description", value: "ilike.*\(query)*"),
            .init(name: "order", value: "logged_at.desc"),
            .init(name: "limit", value: String(limit)),
        ]
        if let start { items.append(.init(name: "logged_at", value: "gte.\(start)")) }
        if let end { items.append(.init(name: "logged_at", value: "lte.\(end)")) }
        let req = try await makeRequest("GET", "rest/v1/nutrition_entries", query: items)
        return try await send(req, as: [NutritionEntry].self)
    }

    public func profile() async throws -> Profile? {
        let req = try await makeRequest("GET", "rest/v1/profiles", query: [
            .init(name: "select", value: "*,goals(type,custom_label,priority)"),
            .init(name: "limit", value: "1"),
        ])
        return try await send(req, as: [Profile].self).first
    }

    // MARK: - Writes (RLS + WITH CHECK enforce ownership)

    /// Manual entry — direct insert.
    public func createEntry(description: String, calories: Int, proteinG: Double, carbsG: Double, fatG: Double,
                            mealType: MealType? = nil, loggedAt: Date = Date(), source: NutritionSource = .manual) async throws -> NutritionEntry {
        struct Body: Encodable {
            let description: String, calories: Int, proteinG: Double, carbsG: Double, fatG: Double
            let mealType: String, loggedAt: Date, source: String
        }
        let body = Body(description: description, calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                        mealType: (mealType ?? MealTypeInference.infer(from: loggedAt)).rawValue,
                        loggedAt: loggedAt, source: source.rawValue)
        let req = try await makeRequest("POST", "rest/v1/nutrition_entries", body: try encoder.encode(body), prefer: "return=representation")
        return try first(await send(req, as: [NutritionEntry].self))
    }

    /// AI logging — text and/or photo go through the `/log` Edge Function (Gemini parses server-side).
    public func logMeal(text: String? = nil, imageBase64: String? = nil, note: String? = nil, mealType: MealType? = nil) async throws -> NutritionEntry {
        struct Body: Encodable { let text: String?; let imageBase64: String?; let note: String?; let mealType: String? }
        let body = Body(text: text, imageBase64: imageBase64, note: note, mealType: mealType?.rawValue)
        let req = try await makeRequest("POST", "functions/v1/log", body: try encoder.encode(body))
        return try await send(req, as: NutritionEntry.self)   // /log returns the single inserted row
    }

    public func updateEntry(id: UUID, description: String? = nil, calories: Int? = nil,
                            proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil, mealType: MealType? = nil) async throws -> NutritionEntry {
        struct Body: Encodable {
            let description: String?; let calories: Int?; let proteinG: Double?; let carbsG: Double?; let fatG: Double?; let mealType: String?
        }
        let body = Body(description: description, calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG, mealType: mealType?.rawValue)
        let req = try await makeRequest("PATCH", "rest/v1/nutrition_entries",
                                        query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                                        body: try encoder.encode(body), prefer: "return=representation")
        return try first(await send(req, as: [NutritionEntry].self))
    }

    public func deleteEntry(id: UUID) async throws {
        let req = try await makeRequest("DELETE", "rest/v1/nutrition_entries",
                                        query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")])
        try await sendNoContent(req)
    }

    /// Override targets (any subset). Writes profile override columns → the targets trigger recomputes.
    public func setTargets(calories: Int? = nil, proteinG: Int? = nil, carbsG: Int? = nil, fatG: Int? = nil) async throws {
        struct Body: Encodable { let tdeeOverride: Int?; let proteinGOverride: Int?; let carbsGOverride: Int?; let fatGOverride: Int? }
        let body = Body(tdeeOverride: calories, proteinGOverride: proteinG, carbsGOverride: carbsG, fatGOverride: fatG)
        try await patchProfile(try encoder.encode(body))
    }

    public func updateProfile(weightLb: Double? = nil, heightCm: Double? = nil, age: Int? = nil,
                              sex: Sex? = nil, trainingDaysPerWeek: Int? = nil, timezone: String? = nil) async throws {
        struct Body: Encodable {
            let weightLb: Double?; let heightCm: Double?; let age: Int?; let sex: String?; let trainingDaysPerWeek: Int?; let timezone: String?
        }
        let body = Body(weightLb: weightLb, heightCm: heightCm, age: age, sex: sex?.rawValue, trainingDaysPerWeek: trainingDaysPerWeek, timezone: timezone)
        try await patchProfile(try encoder.encode(body))
    }

    public func setGoal(_ type: GoalType, customLabel: String? = nil) async throws {
        let uid = try await currentUserId()
        let del = try await makeRequest("DELETE", "rest/v1/goals", query: [.init(name: "profile_id", value: "eq.\(uid)")])
        try await sendNoContent(del)
        struct Body: Encodable { let profileId: String; let type: String; let customLabel: String?; let priority: Int }
        let body = Body(profileId: uid, type: type.rawValue, customLabel: customLabel, priority: 0)
        let req = try await makeRequest("POST", "rest/v1/goals", body: try encoder.encode(body))
        try await sendNoContent(req)
    }

    // MARK: - Plumbing

    private func patchProfile(_ body: Data) async throws {
        let uid = try await currentUserId()
        let req = try await makeRequest("PATCH", "rest/v1/profiles", query: [.init(name: "id", value: "eq.\(uid)")], body: body)
        try await sendNoContent(req)
    }

    private func rpc<T: Decodable>(_ fn: String, body: Data) async throws -> T {
        let req = try await makeRequest("POST", "rest/v1/rpc/\(fn)", body: body)
        return try await send(req, as: T.self)
    }

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, prefer: String? = nil) async throws -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding("\(error)") }
    }

    private func sendNoContent(_ req: URLRequest) async throws {
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    private func first(_ rows: [NutritionEntry]) throws -> NutritionEntry {
        guard let r = rows.first else { throw APIError.emptyResponse }
        return r
    }

    /// Reads `sub` from the (already-validated-by-the-server) JWT to scope profile/goal writes.
    private func currentUserId() async throws -> String {
        let token = try await tokenProvider()
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw APIError.badToken }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String else { throw APIError.badToken }
        return sub
    }
}
