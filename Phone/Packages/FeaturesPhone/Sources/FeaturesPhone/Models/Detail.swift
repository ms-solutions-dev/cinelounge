import Foundation

/// A row of the facts list: the word on the left, the value on the right.
///
/// **A value and not a finished string.** "Director: Skonsta Gutrikian" as one piece would be
/// built wrongly in another language and could not be aligned — and alignment is what
/// happens here: The words stand on the left one below the other, the values on the right.
///
/// **Empty entries do not arise in the first place.** ``Detail/when(_:_:)`` returns `nil`
/// for an empty value, so that the list does not have to check at every spot whether a row
/// has content. A row with a dash is worse than no row: It fills height with the
/// information "nothing here".
public struct Detail: Sendable, Equatable, Identifiable {

    /// The key of the word in the catalog — named in English like all keys.
    public let key: String
    public let value: String

    public var id: String { key }

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    /// Builds the entry only when there is something to say.
    public static func when(_ key: String, _ value: String?) -> Detail? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Detail(key, value)
    }
}
