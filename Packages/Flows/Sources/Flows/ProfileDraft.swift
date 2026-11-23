import ParentalControls
import ProfileKit

/// What is currently entered in the "Create/edit profile" sheet — **the same value
/// on both devices** (G3, finding B1; until then `ProfileSheet.Draft` on the TV).
///
/// **A value and no `@State` in the sheet**, so that the path from sheet to book is a computation:
/// ``ProfileManagement/save(_:existing:)`` takes it, and the checks see
/// what arrives. Until G3 the phone had no creating at all — "Child profiles are created on the
/// TV" was shown there as a hint.
public nonisolated struct ProfileDraft: Equatable, Sendable {

    public var name: String
    public var color: Profile.ColorTag
    /// The kind — **selectable only when creating** (``ProfileManagement/update(_:name:color:avatar:)``
    /// explains why a child does not later become an adult).
    public var kind: Profile.Kind
    /// A child's own limit — **`nil` means "as on the device"**, not "without
    /// limit": The stricter of profile and device always applies.
    public var limit: AgeLimit?
    public var avatar: String?

    public init(
        name: String, color: Profile.ColorTag, kind: Profile.Kind, limit: AgeLimit?,
        avatar: String?
    ) {
        self.name = name
        self.color = color
        self.kind = kind
        self.limit = limit
        self.avatar = avatar
    }

    /// The draft for a new profile or for an existing one — **with the colour that
    /// nobody has yet** (``ProfileManagement/nextColor``) and the limit it already
    /// carries.
    public init(existing: Profile?, suggestion: Profile.ColorTag, previousLimit: AgeLimit?) {
        self.init(
            name: existing?.name ?? "", color: existing?.color ?? suggestion,
            kind: existing?.kind ?? .adult, limit: previousLimit, avatar: existing?.avatar)
    }

    /// The letter of the preview — **empty as long as no name is entered.**
    public var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map {
            String($0).uppercased()
        } ?? ""
    }

    /// Whether the draft can be saved — **an empty name does not save**: A profile
    /// without a name would be a circle without a letter, and nobody would know whose it is.
    public var isValid: Bool { !initial.isEmpty }

    /// Passes the draft on if it is valid — **the limit only for a child.**
    @discardableResult
    public func save(
        _ onSave: (String, Profile.ColorTag, Profile.Kind, AgeLimit?, String?) -> Void
    ) -> Bool {
        guard isValid else { return false }
        onSave(name, color, kind, kind == .kind ? limit : nil, avatar)
        return true
    }

    /// Whether the sheet reminds that nothing locks without a device PIN — **only for a
    /// child:** A child profile without a PIN would be one that can be left with two taps.
    public static func promptsForPin(kind: Profile.Kind, isPinSet: Bool) -> Bool {
        kind == .kind && !isPinSet
    }
}

extension ProfileManagement {

    /// This profile's own limit — `nil` means "as on the device".
    public func limit(forItem identifier: Profile.Identifier) -> AgeLimit? {
        AgeLimit.read(from: keychain, forItem: identifier.rawValue)
    }

    /// Creates a profile or changes it — **including the limit if it is a child** (G3).
    ///
    /// **The limit belongs to the edited profile, otherwise to the new one** — the same rule as
    /// until then in `ProfileView.save` on the TV: An edit must never set the limit
    /// of a freshly created neighbour.
    ///
    /// - Returns: the ID of the new profile, `nil` when changing or with an empty name.
    @discardableResult
    public func save(_ draft: ProfileDraft, existing: Profile?) -> Profile.Identifier? {
        guard draft.isValid else { return nil }
        let fresh: Profile.Identifier?
        if let existing {
            update(existing.identifier, name: draft.name, color: draft.color, avatar: draft.avatar)
            fresh = nil
        } else {
            fresh = create(name: draft.name, color: draft.color, kind: draft.kind, avatar: draft.avatar)
        }
        let kind = existing?.kind ?? draft.kind
        if kind == .kind, let target = existing?.identifier ?? fresh {
            AgeLimit.write(draft.limit, in: keychain, forItem: target.rawValue)
        }
        return fresh
    }
}
