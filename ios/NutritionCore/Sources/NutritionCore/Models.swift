import Foundation

// Codable models matching the Supabase API (PostgREST rows + the nutrition_day/range RPC JSON).
// snake_case ↔ camelCase is handled by the decoder/encoder in Coding.swift.

public enum MealType: String, Codable, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack
}

public enum NutritionSource: String, Codable, Sendable {
    case manual
    case aiText = "ai_text"
    case aiPhoto = "ai_photo"
}

public enum Sex: String, Codable, Sendable {
    case male, female
    case preferNotToSay = "prefer_not_to_say"
}

public enum GoalType: String, Codable, Sendable {
    case fatLoss = "fat_loss"
    case muscleGain = "muscle_gain"
    case strength
    case generalHealth = "general_health"
    case custom
}

/// A logged meal (the `nutrition_entries` row).
public struct NutritionEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let userId: UUID
    public let loggedAt: Date
    public let mealType: MealType
    public let description: String
    public let calories: Int
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
    public let source: NutritionSource
    public let aiConfidence: Double?
    public let createdAt: Date
    public let updatedAt: Date
}

/// A calorie + macro bundle (totals / targets / remaining, from the RPCs).
public struct Macros: Codable, Sendable {
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
}

/// `nutrition_day` RPC result — everything needed to render a day, math pre-computed.
public struct DaySummary: Codable, Sendable {
    public let date: String          // local date (YYYY-MM-DD), not a timestamp
    public let timezone: String
    public let totals: Macros
    public let targets: Macros?
    public let remaining: Macros?
    public let entries: [NutritionEntry]
}

public struct DayTotals: Codable, Sendable {
    public let date: String
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
}

/// `nutrition_range` RPC result — per-day series + averages.
public struct RangeSummary: Codable, Sendable {
    public let start: String
    public let end: String
    public let timezone: String
    public let days: [DayTotals]
    public let averages: Macros?
}

public struct NutritionTargets: Codable, Sendable {
    public let calories: Int
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
}

public struct Goal: Codable, Sendable {
    public let type: GoalType
    public let customLabel: String?
    public let priority: Int
}

public struct Profile: Codable, Sendable {
    public let id: UUID
    public let name: String?
    public let heightCm: Double?
    public let weightLb: Double?
    public let age: Int?
    public let sex: Sex
    public let trainingDaysPerWeek: Int
    public let dietaryPreference: String?
    public let timezone: String
    public let tdeeOverride: Int?
    public let proteinGOverride: Int?
    public let carbsGOverride: Int?
    public let fatGOverride: Int?
    public let goals: [Goal]
}
