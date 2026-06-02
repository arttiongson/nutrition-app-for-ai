import Testing
import Foundation
@testable import NutritionCore

// Swift Testing (toolchain-bundled) — runs under `swift test` with the CLI tools, no Xcode needed.

private let decoder = JSONDecoder.supabase()

@Test func mealTypeInferenceBands() {
    func at(_ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: hour, minute: 0))!
    }
    #expect(MealTypeInference.infer(from: at(8)) == .breakfast)
    #expect(MealTypeInference.infer(from: at(12)) == .lunch)
    #expect(MealTypeInference.infer(from: at(18)) == .dinner)
    #expect(MealTypeInference.infer(from: at(22)) == .snack)
    #expect(MealTypeInference.infer(from: at(2)) == .snack)
}

// Real PostgREST row captured from the live API (microsecond ISO date, numeric formatting).
@Test func decodeRealEntry() throws {
    let json = #"""
    {"id":"da0b4879-73fd-438d-ae84-b91e4c0fe81a","user_id":"24db6ede-3204-4c36-a0b2-aedf2697031b","logged_at":"2026-06-02T19:11:14.847869+00:00","meal_type":"lunch","description":"shape probe","calories":700,"protein_g":50.00,"carbs_g":70.50,"fat_g":20.00,"source":"manual","ai_confidence":0.820,"created_at":"2026-06-02T19:11:14.847869+00:00","updated_at":"2026-06-02T19:11:14.847869+00:00"}
    """#
    let e = try decoder.decode(NutritionEntry.self, from: Data(json.utf8))
    #expect(e.calories == 700)
    #expect(abs(e.proteinG - 50) < 0.001)
    #expect(abs(e.carbsG - 70.5) < 0.001)
    #expect(abs(e.fatG - 20) < 0.001)
    #expect(e.source == .manual)
    #expect(e.mealType == .lunch)
    #expect(abs((e.aiConfidence ?? -1) - 0.82) < 0.001)
    #expect(e.id.uuidString.lowercased() == "da0b4879-73fd-438d-ae84-b91e4c0fe81a")
}

// Real nutrition_day RPC result (totals/targets/remaining + nested entry with null ai_confidence).
@Test func decodeRealDaySummary() throws {
    let json = #"""
    {"date":"2026-06-01","timezone":"America/Los_Angeles","totals":{"fat_g":30,"carbs_g":130,"calories":1100,"protein_g":65},"targets":{"fat_g":83,"carbs_g":337,"calories":2995,"protein_g":225},"remaining":{"fat_g":53,"carbs_g":207,"calories":1895,"protein_g":160},"entries":[{"id":"d1006b0d-6859-401b-bfdc-199facaf0bca","fat_g":20,"source":"manual","carbs_g":70,"user_id":"33333333-3333-3333-3333-333333333333","calories":700,"logged_at":"2026-06-01T22:12:25.680423+00:00","meal_type":"lunch","protein_g":50,"created_at":"2026-06-01T22:12:25.680423+00:00","updated_at":"2026-06-01T22:12:25.680423+00:00","description":"chicken bowl","ai_confidence":null}]}
    """#
    let d = try decoder.decode(DaySummary.self, from: Data(json.utf8))
    #expect(d.date == "2026-06-01")
    #expect(d.timezone == "America/Los_Angeles")
    #expect(abs(d.totals.calories - 1100) < 0.001)
    #expect(abs((d.targets?.calories ?? -1) - 2995) < 0.001)
    #expect(abs((d.remaining?.proteinG ?? -1) - 160) < 0.001)
    #expect(d.entries.count == 1)
    #expect(d.entries.first?.description == "chicken bowl")
    #expect(d.entries.first?.aiConfidence == nil)
}

@Test func sourceEnumMapping() throws {
    let arr = try decoder.decode([NutritionSource].self, from: Data(#"["manual","ai_text","ai_photo"]"#.utf8))
    #expect(arr == [.manual, .aiText, .aiPhoto])
}

// Write bodies must serialize camelCase → snake_case for the API.
@Test func encoderSnakeCase() throws {
    struct Body: Encodable { let imageBase64: String; let mealType: String; let proteinGOverride: Int }
    let s = String(data: try JSONEncoder.supabase().encode(Body(imageBase64: "abc", mealType: "lunch", proteinGOverride: 200)), encoding: .utf8)!
    #expect(s.contains("image_base64"))
    #expect(s.contains("meal_type"))
    #expect(s.contains("protein_g_override"))
}
