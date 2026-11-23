import Foundation

/// The decoder with which the server's responses are read.
///
/// Needed because of a quirk that no standard tool covers: Jellyfin
/// writes timestamps with **seven** fractional digits, for example
/// `2022-04-03T22:00:00.0000000Z`. The built-in ISO-8601 parsing expects
/// at most three and silently fails on every title that carries a
/// first-air or end date.
public enum JellyfinDecoder {

    public static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            guard let date = parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown time format: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    /// Tries the known spellings in turn.
    ///
    /// The server is not consistent here: Some fields carry
    /// fractions of a second, others do not, and some end in `Z`, others in
    /// a time zone offset.
    static func parse(_ raw: String) -> Date? {
        if let date = fractionalFormatter.date(from: normalized(raw)) {
            return date
        }
        if let date = plainFormatter.date(from: raw) {
            return date
        }
        return nil
    }

    /// Trims surplus fractional digits to the three that the
    /// ISO-8601 parsing can handle.
    static func normalized(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }

        let afterDot = raw.index(after: dot)
        let fractionEnd =
            raw[afterDot...].firstIndex { !$0.isNumber } ?? raw.endIndex
        let fraction = raw[afterDot..<fractionEnd]

        guard fraction.count > 3 else { return raw }

        let trimmed = fraction.prefix(3)
        return String(raw[..<afterDot]) + String(trimmed) + String(raw[fractionEnd...])
    }

    // The formatters are created once and afterwards only read.
    // `ISO8601DateFormatter` is safe to use from several tasks when
    // parsing; the language check cannot recognize that because the
    // type is not marked accordingly. Creating a formatter per call
    // would be the alternative — but noticeably more expensive with a media library
    // of thousands of titles.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
