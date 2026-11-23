import Foundation

/// **In PortalKit since AP58 G1** (decision 27, A9): the source choice in the player now exists
/// on both devices, and the decomposition beneath it is the same. Until then it lay in
/// `FeaturesPhone`, and the TV knew none.
private let point = " · "

/// A row from `/sources` — **and not what its name promises.**
///
/// Measured on 2026-09-06 at the real bridge, and the measurement decides the build:
///
/// | Portal | Rows for **one** episode | What is in them |
/// |---|---|---|
/// | Animehub | 12 | 4 hosts × 3 language versions |
/// | Serieshub | 3 | 1 host × 3 language versions |
/// | ARD Mediathek | 10 | 5 resolution levels × 2 audio versions |
///
/// **A flat list from it shows "HOSTA" four times one below the other**, and for the ARD no host
/// at all, but "HD 1080p". What is on offer is two to three things in a cross product; they are
/// separated in ``PortalSourceChoice``.
public struct PortalHost: Sendable, Equatable, Identifiable {

    /// The identifier that the bridge expects in `/play?source=`.
    public let id: String
    /// What the portal calls the row — "HOSTA", "HD 1080p", "SD 540p · Audiodeskription".
    public let name: String
    /// The language version as the portal writes it — "(DE)", "(JPN) Sub: (EN)".
    public let language: String?
    public let locked: Bool
    /// Why blocked — the bridge's sentence, verbatim.
    public let reason: String?

    public init(
        id: String, name: String, language: String? = nil, locked: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.locked = locked
        self.reason = reason
    }

    /// From the bridge's row — **one mapping for both devices.**
    public init(_ raw: PortalFileHost) {
        self.init(
            id: raw.id, name: raw.name, language: raw.language, locked: raw.locked,
            reason: raw.reason)
    }

    /// The name without the suffix behind it — "SD 540p · Audiodeskription" becomes "SD 540p".
    public var header: String {
        String(name.split(separator: point).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// What stands behind the dot, where something stands — "Audiodeskription".
    public var extras: String? {
        let split = name.components(separatedBy: point)
        guard split.count > 1 else { return nil }
        let rest = split.dropFirst().joined(separator: point)
            .trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The provider — **or `nil` if this row is a level.**
    public var provider: String? { isTier ? nil : header }

    /// The resolution level — **or `nil` if this row is a provider.**
    public var tier: String? { isTier ? header : nil }

    /// The version: the portal's language, otherwise the suffix behind the dot.
    ///
    /// **Both are the same field for the viewer** — "in which version" —, and both never occur at
    /// once: the host portals name `language` and no suffix, the ARD a suffix and no `language`.
    public var version: String? { language ?? extras }

    /// Whether the head of this row names a resolution level.
    ///
    /// **Measured and narrowly drawn: a number with `p`, or the word "Auto".** The ten ARD rows are
    /// called "HD 1080p", "HD 720p", "SD 540p", "SD 360p" and "Auto".
    ///
    /// **What is not recognised counts as a provider** — and that is the safe direction: a row that
    /// wrongly counts as a provider is visible in the list and selectable; one that wrongly counts
    /// as a level disappears from the provider choice. Keeping a table over third-party strings that
    /// are allowed to change would be the mistake that ``LanguageTag/short(_:)`` already warns about.
    public var isTier: Bool {
        let words = header.split(separator: " ")
        if words.count == 1, words[0].lowercased() == "auto" { return true }
        return words.contains { word in
            word.count > 1 && word.hasSuffix("p") && word.dropLast().allSatisfy(\.isNumber)
        }
    }
}

/// The rows from `/sources`, **broken down into their questions.**
///
/// The viewer answers in turn "with whom", "how big" and "which version" — the bridge delivers
/// the finished cross product for it. This decomposition is pure computation without network and
/// without state; that is why it is testable, and that is why it does not sit in the view.
///
/// **There are never all three at once.** Where hosts exist, there are no levels; where levels
/// exist, no hosts. The sheet is built three-stage anyway: which two it is, the portal decides,
/// not the build — and a portal that carries both would no longer be a special case.
public struct PortalSourceChoice: Sendable, Equatable {

    public let rows: [PortalHost]

    public init(_ rows: [PortalHost]) {
        self.rows = rows
    }

    /// The providers in the order in which the bridge names them.
    ///
    /// **Not sorted, and that is a decision.** The bridge pulls the sources of the chosen language to
    /// the front and works through them in `/play` from the top; ordering alphabetically would
    /// silently override that choice.
    public var provider: [String] { onlyOnce(rows.compactMap(\.provider)) }

    public var slots: [String] { onlyOnce(rows.compactMap(\.tier)) }

    public var variants: [String] { onlyOnce(rows.compactMap(\.version)) }

    /// The row that belongs to a choice — `nil` if there is none.
    ///
    /// **What is not chosen does not restrict.** Whoever gives only the provider gets its first row;
    /// that is the same rule by which the bridge, without any statement, takes the first usable host.
    ///
    /// **Blocked ones do not come out.** They are in the list so that it is visible why they do not
    /// work — they cannot be played, and `/play` would give an error on them instead of a picture.
    public func match(
        provider: String? = nil, tier: String? = nil, version: String? = nil
    )
        -> PortalHost?
    {
        rows.first { row in
            guard !row.locked else { return false }
            if let provider, row.provider != provider { return false }
            if let tier, row.tier != tier { return false }
            if let version, row.version != version { return false }
            return true
        }
    }

    /// Whether there is anything to choose at all.
    ///
    /// **A single row is no choice** — then the button is dropped, instead of opening a sheet in
    /// which one row stands with a checkmark. The same rule as with the language versions and with
    /// the audio choice in the phone's source sheet.
    public var isWorthwhile: Bool {
        provider.count > 1 || slots.count > 1 || variants.count > 1
    }

    /// Which of the three questions is currently being answered.
    public enum Field: Sendable, CaseIterable {
        case provider, tier, version
    }

    /// A value to choose — **with the reason if it does not work.**
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public var id: String { value }
        public let value: String
        /// The row that would result. `nil` means: this combination does not exist.
        public let target: PortalHost?
        /// Why it does not work — the bridge's sentence, where it has one.
        public let reason: String?

        public var selectable: Bool { target != nil }
    }

    /// The values of a field, each with what would happen on choosing it.
    ///
    /// **An unselectable row stays and merely becomes unselectable** — the same rule as with a
    /// silent portal in the portal choice: "setting missing" answers the question of
    /// why nothing works there; a missing entry answers nothing at all.
    ///
    /// **And that is at the same time the protection against a button without effect.** Whoever
    /// filtered out only the blocked ones would have rows that can be pressed and do nothing.
    public func suggestions(
        forItem field: Field, provider: String? = nil, tier: String? = nil, version: String? = nil
    ) -> [Suggestion] {
        let values: [String]
        switch field {
        case .provider: values = self.provider
        case .tier: values = slots
        case .version: values = variants
        }
        return values.map { value in
            let target = match(
                provider: field == .provider ? value : provider,
                tier: field == .tier ? value : tier,
                version: field == .version ? value : version)
            // The reason comes from the blocked row with **this** value — the other conditions are dropped
            // for it: the question is why this value does not work, not why this combination is missing.
            let blocked = rows.first { row in
                row.locked && Self.value(from: row, field: field) == value
            }
            return Suggestion(value: value, target: target, reason: target == nil ? blocked?.reason : nil)
        }
    }

    public static func value(from row: PortalHost, field: Field) -> String? {
        switch field {
        case .provider: row.provider
        case .tier: row.tier
        case .version: row.version
        }
    }

    private func onlyOnce(_ values: [String]) -> [String] {
        var seenValues = Set<String>()
        return values.filter { seenValues.insert($0).inserted }
    }
}

/// DE, JA, OmU — **the mark of a language version, as a portal names it.**
///
/// **Shortened, not translated.** The words come from the portal ("Deutsch", "Japanisch mit
/// Untertiteln", "German Sub"); translating them would mean keeping a table over third-party
/// strings that are allowed to change. Only what is unambiguous is shortened — everything else
/// stands as it came. Shared since AP58 G1: on the TV the same mark is in the track board.
public enum LanguageTag {

    public static func short(_ version: String) -> String {
        let lowercased = version.lowercased()
        if lowercased.contains("sub") || lowercased.contains("untertitel") { return "OmU" }
        if lowercased.hasPrefix("deutsch") || lowercased.hasPrefix("german") { return "DE" }
        if lowercased.hasPrefix("japan") { return "JA" }
        if lowercased.hasPrefix("englisch") || lowercased.hasPrefix("english") { return "EN" }
        return version
    }
}
