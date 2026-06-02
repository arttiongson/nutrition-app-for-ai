# NutritionCore

The standalone Swift core for the iOS app — the **SwiftData → API re-point**. No SwiftData:
plain `Codable` models, a `NutritionAPI` client over Supabase (PostgREST + the `/log` Edge
Function + RLS), and the ported `MealTypeInference`. Every call runs under the user's Supabase
JWT, so RLS confines it to their own rows (same isolation as the MCP server).

## What's here
- `Models.swift` — `NutritionEntry`, `Macros`, `DaySummary`, `RangeSummary`, `NutritionTargets`, `Profile`, enums.
- `NutritionAPI.swift` — reads (`today`/`day`/`range`/`targets`/`searchEntries`/`profile`) and writes (`createEntry`, `logMeal`, `updateEntry`, `deleteEntry`, `setTargets`, `updateProfile`, `setGoal`).
- `Coding.swift` — snake_case ↔ camelCase + Postgres microsecond-ISO date handling.
- `MealTypeInference.swift` — time-of-day → meal type.

## Verify
```bash
swift build                 # compiles the library
swift run NutritionCoreVerify   # runs checks against real captured API JSON (no Xcode needed)
```
Full test suite (`Tests/`, Swift Testing) runs in Xcode / CI — XCTest and Testing ship with
Xcode, not the Command Line Tools, so use `NutritionCoreVerify` for CLI-only verification.

## Usage
```swift
let api = NutritionAPI(baseURL: URL(string: "https://<ref>.supabase.co")!,
                       apiKey: "<publishable key>") { await session.accessToken() }
let day = try await api.today()           // totals, targets, remaining — pre-computed
_ = try await api.logMeal(text: "chicken bowl, 700 cal")
```
