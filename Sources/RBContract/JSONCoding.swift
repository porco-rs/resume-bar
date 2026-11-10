// JSON coding for fixtures and persisted values. Fixture dates come in two ISO 8601 forms:
// "2026-11-02T12:00:00+01:00" and "2026-11-02T10:48:00.000Z".

import Foundation

public enum RBJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(raw)")
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func parseDate(_ raw: String) -> Date? {
        if let d = try? Date(raw, strategy: .iso8601) { return d }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? fractional.parse(raw)
    }
}
