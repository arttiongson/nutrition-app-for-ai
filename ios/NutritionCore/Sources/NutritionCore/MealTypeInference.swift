import Foundation

/// Infers a default meal type from a timestamp so the add-meal UI can pre-fill it.
/// Ported verbatim from art-fitness. Bands:
///   04:00–10:59 breakfast · 11:00–14:59 lunch · 17:00–20:59 dinner · else snack
public enum MealTypeInference {
    public static func infer(from date: Date = Date(), calendar: Calendar = .current) -> MealType {
        switch calendar.component(.hour, from: date) {
        case 4..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<21: return .dinner
        default: return .snack
        }
    }
}
