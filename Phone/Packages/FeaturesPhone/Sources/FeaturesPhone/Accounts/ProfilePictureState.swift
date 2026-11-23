import Core
import Diagnose
import Flows
import Foundation
import Observation
import ProfileKit

/// Who carries which profile picture — **read from the ``ProfileKit/ProfileBook``, written to it.**
///
/// **Until AP49 the phone had no place that changes a profile.** Profiles arise
/// here at the end of setup (``SetupState``) and come over the cloud from the
/// TV; accounts were displayed. This class is the narrowest holder that can do both:
/// look up the image for an account and write a choice into the book.
///
/// **Since AP58 R7 writing goes through the shared ``Flows/ProfileManagement``** —
/// the same one through which the TV changes name, color and image, including the immediate
/// push up to the cloud. The reconciliation reads the book and not this class.
///
/// **A holder and not a second store.** ``ledger`` is the most recently read version, so that
/// the header does not read the file on every redraw; it is re-read on
/// ``load()`` — after saving, when opening the person sheet and when coming back to the
/// foreground, where a reconciliation may meanwhile have brought an image from the TV.
@MainActor
@Observable
public final class ProfilePictureState {

    /// The most recently read version of the book.
    public private(set) var ledger: ProfileBook

    private let store: any KeyValueStore
    /// The shared management (``Flows/ProfileManagement``, AP58 R7) — **the same way
    /// into the book and into the cloud as on the TV**, not a second version of it.
    private let administration: ProfileManagement

    /// - Parameter ablage: where the ``ProfileKit/ProfileBook`` lives — in the app the
    ///   `FileStore`, in the checks an in-memory store.
    /// - Parameter wolke: **Asked for on every save** and not fixed at construction —
    ///   the cloud connects only after launch.
    public init(store: any KeyValueStore, cloud: @escaping @MainActor () -> ProfileCloud?) {
        self.store = store
        self.administration = ProfileManagement(store: store, cloud: cloud)
        self.ledger = ProfileBook.read(from: store)
    }

    /// Reads the book again.
    public func load() {
        ledger = ProfileBook.read(from: store)
    }

    /// The profile this account belongs to — **or none.**
    ///
    /// **Strict and without fallback**, because it is asked for every row of the account list:
    /// a fallback to the active profile would put its face on foreign accounts.
    /// Assignment is by the same identifier "Server|Benutzer" with which
    /// ``SetupState`` recognizes a profile's media server.
    public func profile(toAccount account: Account.Identifier) -> Profile? {
        Self.profile(toAccount: account, in: ledger)
    }

    /// The profile that the header and the person sheet show.
    ///
    /// **First the one of the signed-in account, otherwise the active one.** A phone without a
    /// media server has a profile all the same (with only a channel list or portals), and its
    /// image belongs at the top right just as well.
    public func headerProfile(signedIn: Account.Identifier?) -> Profile? {
        if let signedIn, let own = Self.profile(toAccount: signedIn, in: ledger) {
            return own
        }
        return ledger.activeProfile
    }

    /// Writes the choice into the book — **through the same way as name and color on the TV.**
    ///
    /// Only the image: name, color and kind of the profile stay as they are. A profile that
    /// no longer exists (the cloud removed it while the sheet was
    /// open) stays unwritten — ``ProfileKit/ProfileBook/update(_:_:)`` then does nothing,
    /// and the book is re-read all the same.
    public func save(_ choice: ProfilePictureChoice) {
        administration.setPicture(choice.identifier, avatar: choice.avatar)
        Diagnose.step(
            .surface,
            "Profile picture saved: \(choice.hasNoPictureChosen ? "letter" : choice.avatar ?? "")"
        )
        load()
    }

    static func profile(toAccount account: Account.Identifier, in ledger: ProfileBook) -> Profile? {
        ledger.profile.first { $0.jellyfin?.legacyAccountID == account.stored }
    }
}

/// What is currently chosen in the image-picker sheet — **and what of it goes out when saving.**
///
/// **A value and not a `@State` in the sheet**, so that the path from the sheet into the book is a calculation
/// and not a line in the button body: `ProfilePictureTests` checks that the choice arrives.
/// Exactly this connection is the one you do not see on screen — the preview showed
/// the image, yet it would not have been saved.
///
/// **Only from the bundled set.** There is no free input; ``select(_:)`` takes
/// a ``ProfileKit/AvatarMotif`` and not a name. Thus the rule "child profiles choose
/// only from a vetted set" holds for every profile, without a child profile
/// needing a switch of its own.
public struct ProfilePictureChoice: Equatable, Sendable {

    /// Whose image is being chosen.
    public let identifier: Profile.Identifier
    /// The name of the profile — for the letter in the preview.
    public let name: String
    /// The color of the profile — for the letter and the cover image without a motif.
    public let color: Profile.ColorTag
    /// The chosen motif — **`""` means "No image", `nil` "never decided".**
    ///
    /// **The difference is a contract with the cloud and not a subtlety** (2026-09-25,
    /// finding of the second review): `nil` is never pushed up, because an empty value
    /// would arrive in the reconciliation as a deletion order and destroy the image that another device
    /// set. Whoever chooses "No image" here has decided — and that is what `""` says.
    /// Both are drawn the same: ``ProfileKit/AvatarMotif/motif(forItem:)`` returns
    /// no motif for both.
    public private(set) var avatar: String?

    /// Starts with the image the profile already carries.
    public init(profile: Profile) {
        identifier = profile.identifier
        name = profile.name
        color = profile.color
        avatar = profile.avatar
    }

    /// The letter of the preview — the same as ``ProfileKit/Profil/initial``.
    public var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    public mutating func select(_ motif: AvatarMotif) {
        avatar = motif.name
    }

    /// "No image" — back to the letter, **as an empty name and not as `nil`.**
    public mutating func withoutImage() {
        avatar = ""
    }

    /// Whether "No image" is chosen — **`nil` and `""` alike.** A profile that never
    /// had an image opens the choice with this tile marked.
    public var hasNoPictureChosen: Bool {
        avatar?.isEmpty ?? true
    }
}
