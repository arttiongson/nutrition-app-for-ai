import Foundation

/// Parses the ISO8601 timestamps Postgres returns (microsecond precision + offset,
/// e.g. "2026-06-02T19:11:14.847869+00:00"). ISO8601DateFormatter only handles ≤3
/// fractional digits, so we truncate microseconds → milliseconds as a fallback.
enum ISO8601Parsing {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from raw: String) -> Date? {
        if let d = withFractional.date(from: raw) { return d }
        if let d = plain.date(from: raw) { return d }
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw.index(after: dot)
        guard let tzStart = raw[afterDot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let frac = raw[afterDot..<tzStart]
        guard frac.count > 3 else { return nil }
        let truncated = raw.replacingCharacters(in: afterDot..<tzStart, with: String(frac.prefix(3)))
        return withFractional.date(from: truncated)
    }
}

extension JSONDecoder {
    /// Decoder for Supabase responses: snake_case keys + Postgres timestamps.
    public static func supabase() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601Parsing.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unparseable date: \(raw)"))
            }
            return date
        }
        return d
    }
}

extension JSONEncoder {
    /// Encoder for write bodies: camelCase → snake_case, ISO8601 dates.
    public static func supabase() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
