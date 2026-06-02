import Foundation
import NutritionCore

// No-Xcode verification: decodes the real captured API JSON + checks the ported logic.
// Run with `swift run NutritionCoreVerify`. Mirrors Tests/NutritionCoreTests (Swift Testing).

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print((cond ? "✓ " : "✗ FAIL — ") + label)
    if !cond { failures += 1 }
}

let decoder = JSONDecoder.supabase()

// MealTypeInference bands
func at(_ hour: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: hour, minute: 0))!
}
check(MealTypeInference.infer(from: at(8)) == .breakfast, "infer 08:00 → breakfast")
check(MealTypeInference.infer(from: at(12)) == .lunch, "infer 12:00 → lunch")
check(MealTypeInference.infer(from: at(18)) == .dinner, "infer 18:00 → dinner")
check(MealTypeInference.infer(from: at(22)) == .snack, "infer 22:00 → snack")

// Decode a real PostgREST entry row (microsecond ISO date, numeric formatting)
do {
    let json = #"""
    {"id":"da0b4879-73fd-438d-ae84-b91e4c0fe81a","user_id":"24db6ede-3204-4c36-a0b2-aedf2697031b","logged_at":"2026-06-02T19:11:14.847869+00:00","meal_type":"lunch","description":"shape probe","calories":700,"protein_g":50.00,"carbs_g":70.50,"fat_g":20.00,"source":"manual","ai_confidence":0.820,"created_at":"2026-06-02T19:11:14.847869+00:00","updated_at":"2026-06-02T19:11:14.847869+00:00"}
    """#
    let e = try decoder.decode(NutritionEntry.self, from: Data(json.utf8))
    check(e.calories == 700 && abs(e.proteinG - 50) < 0.001 && abs(e.carbsG - 70.5) < 0.001 && abs(e.fatG - 20) < 0.001, "entry macros decode")
    check(e.source == .manual && e.mealType == .lunch, "entry enums decode")
    check(abs((e.aiConfidence ?? -1) - 0.82) < 0.001, "entry ai_confidence decode")
    check(e.loggedAt.timeIntervalSince1970 > 1_700_000_000, "microsecond ISO date parsed")
} catch { check(false, "decode entry threw: \(error)") }

// Decode a real nutrition_day RPC result (totals/targets/remaining + nested entry, null confidence)
do {
    let json = #"""
    {"date":"2026-06-01","timezone":"America/Los_Angeles","totals":{"fat_g":30,"carbs_g":130,"calories":1100,"protein_g":65},"targets":{"fat_g":83,"carbs_g":337,"calories":2995,"protein_g":225},"remaining":{"fat_g":53,"carbs_g":207,"calories":1895,"protein_g":160},"entries":[{"id":"d1006b0d-6859-401b-bfdc-199facaf0bca","fat_g":20,"source":"manual","carbs_g":70,"user_id":"33333333-3333-3333-3333-333333333333","calories":700,"logged_at":"2026-06-01T22:12:25.680423+00:00","meal_type":"lunch","protein_g":50,"created_at":"2026-06-01T22:12:25.680423+00:00","updated_at":"2026-06-01T22:12:25.680423+00:00","description":"chicken bowl","ai_confidence":null}]}
    """#
    let d = try decoder.decode(DaySummary.self, from: Data(json.utf8))
    check(d.date == "2026-06-01" && d.timezone == "America/Los_Angeles", "day meta decode")
    check(abs(d.totals.calories - 1100) < 0.001, "day totals decode")
    check(abs((d.targets?.calories ?? -1) - 2995) < 0.001 && abs((d.remaining?.proteinG ?? -1) - 160) < 0.001, "day targets/remaining decode")
    check(d.entries.count == 1 && d.entries.first?.description == "chicken bowl" && d.entries.first?.aiConfidence == nil, "nested entry + null confidence")
} catch { check(false, "decode day threw: \(error)") }

// Source enum mapping
do {
    let arr = try decoder.decode([NutritionSource].self, from: Data(#"["manual","ai_text","ai_photo"]"#.utf8))
    check(arr == [.manual, .aiText, .aiPhoto], "source enum mapping")
} catch { check(false, "source enum threw: \(error)") }

// Encoder snake_case for write bodies
do {
    struct Body: Encodable { let imageBase64: String; let mealType: String; let proteinGOverride: Int }
    let s = String(data: try JSONEncoder.supabase().encode(Body(imageBase64: "abc", mealType: "lunch", proteinGOverride: 200)), encoding: .utf8)!
    check(s.contains("image_base64") && s.contains("meal_type") && s.contains("protein_g_override"), "encoder camelCase → snake_case")
} catch { check(false, "encoder threw: \(error)") }

// NutritionAuth Session decode + expiry logic (offline)
do {
    let json = #"{"access_token":"abc","token_type":"bearer","expires_in":3600,"expires_at":4102444800,"refresh_token":"r"}"#
    let s = try JSONDecoder.supabase().decode(Session.self, from: Data(json.utf8))
    check(s.accessToken == "abc" && s.refreshToken == "r" && s.tokenType == "bearer", "session decode")
    check(!s.isExpired(now: Date(timeIntervalSince1970: 1_780_000_000)), "session not expired (future expiry)")
    check(s.isExpired(now: Date(timeIntervalSince1970: 4_200_000_000)), "session expired (past expiry)")
} catch { check(false, "session decode threw: \(error)") }

print(failures == 0 ? "\nALL CHECKS PASSED ✅" : "\n\(failures) CHECK(S) FAILED ❌")
exit(failures == 0 ? 0 : 1)
