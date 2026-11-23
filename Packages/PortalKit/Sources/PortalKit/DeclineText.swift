import Foundation

extension PortalBridge.TestError {

    /// The language key for this refusal — `nil` only for the literal reason of the old
    /// bridge.
    ///
    /// `stream.geo_blocked` becomes `error.stream.geo_blocked`. The prefix lives here and
    /// not in every catalog: a code comes from the server, a key belongs to the app, and
    /// the conversion is a rule and not a list.
    ///
    /// **Even a silent or unreadable service has a key** (check 2026-09-27, design B2):
    /// until then the German `errorDescription` stood there, in every language. All
    /// sentences are in the shared catalog `WordingKit`.
    public var sentenceKey: String? {
        switch self {
        case .cancelled(_, let code, _): "error." + code
        case .unreachable: "error.portal.unreachable"
        case .unreadable: "error.portal.unreadable"
        case .rejected: nil
        }
    }

    /// What is displayed when there is **no** translated sentence.
    ///
    /// **The code and not an empty text.** A message without a translation should stand
    /// out instead of silently vanishing — a screen on which nothing is written cannot be
    /// told from a screen that has a gap. For the bridge the fallback is its own wording;
    /// it sends it along, and it is usually all the information one needs.
    public var fallbackText: String {
        switch self {
        case .cancelled(_, let code, _): code
        case .rejected(_, let reason): reason
        case .unreachable, .unreadable: errorDescription ?? ""
        }
    }

    /// The sentence for this refusal, in the app's language.
    ///
    /// **The app looks it up, not this package.** `PortalKit` knows no language files —
    /// and should not: it carries two programs with two catalogs. That is why the one
    /// question it cannot answer is passed in: `lookUp` returns the sentence for a
    /// key or `nil`.
    ///
    /// **The placeholders are named instead of counted.** The server sends its values as a
    /// dictionary (`{"country":"DE"}`), and a dictionary has no order. With `%@` the
    /// sentence would depend on the sequence in which someone inserts the values — with
    /// `{country}` in the sentence it depends only on the name being right. A placeholder
    /// for which no value comes stays in place: that is visible and therefore fixable.
    public func message(lookUp: (String) -> String?) -> String {
        guard let sentenceKey, let template = lookUp(sentenceKey) else {
            return fallbackText
        }
        guard case .cancelled(_, _, let values) = self, !values.isEmpty else { return template }
        return values.reduce(template) { message, pair in
            message.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }
}
