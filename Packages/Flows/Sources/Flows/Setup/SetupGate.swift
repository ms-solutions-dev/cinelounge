import Foundation
import ProfileKit

/// Whether the first setup comes at all — **a calculation over the book and what this device
/// can open** (AP88 §1.5).
///
/// **No "setup finished" marker.** It would be a second truth beside the book, the kind
/// `RootView.settle()` has rejected since AP41: an interrupted setup resumes because the book
/// says so, not because a flag forgot to be set.
nonisolated public enum SetupGate {

    /// What this device can open — **read from the Keychain and the list store, not from the
    /// book.**
    public struct UsableSources: Sendable, Equatable {
        /// `server|user` of every media-server account with a token in this Keychain
        /// (`SecureStore.allAccounts()`).
        public var jellyfinAccounts: Set<String>
        /// The IDs of the channel lists in the list store.
        public var channelLists: Set<String>
        /// The profiles whose compartment holds a CL-Server device trait (`DeviceTrait`).
        public var clServerProfiles: Set<Profile.Identifier>

        public init(
            jellyfinAccounts: Set<String> = [], channelLists: Set<String> = [],
            clServerProfiles: Set<Profile.Identifier> = []
        ) {
            self.jellyfinAccounts = jellyfinAccounts
            self.channelLists = channelLists
            self.clServerProfiles = clServerProfiles
        }
    }

    /// Where the setup begins.
    public enum Entry: Sendable, Equatable {
        /// A1/A2.
        case fresh
        /// A4 for the active profile.
        case resume(Profile.Identifier)
    }

    /// Whether this profile can play anything on this device.
    ///
    /// **What came from iCloud does not count by itself.** A Jellyfin access without a token only
    /// says where one would have to sign in, and a CL-Server person without a device trait here
    /// only says who would have to be admitted — the concept's `portalPerson != nil` would let a
    /// profile from iCloud skip the setup on a device the server has never seen. **A bare bridge
    /// without persons** (`portals(person: nil)`) still counts as before: its wish is all there
    /// is, and an installation with it must not land in the setup after the update.
    public static func canPlay(_ profile: Profile, with usable: UsableSources) -> Bool {
        if let account = profile.jellyfin?.legacyAccountID, usable.jellyfinAccounts.contains(account) {
            return true
        }
        if profile.channelLists.contains(where: {
            $0.channelListID.map(usable.channelLists.contains) ?? false
        }) {
            return true
        }
        guard profile.wantsPortals else { return false }
        return profile.portalPerson == nil || usable.clServerProfiles.contains(profile.identifier)
    }

    /// `nil` means no setup — "Who is watching?" or the main screen, as today.
    ///
    /// **Existing installations never see the setup** as long as one of their profiles can play
    /// something — even if the active one cannot (a child without sources of its own) or none is
    /// active. Only when nothing here plays does the setup come: back into A4 with the active
    /// profile, otherwise from A1.
    public static func entry(book: ProfileBook, usable: UsableSources) -> Entry? {
        guard !book.profile.contains(where: { canPlay($0, with: usable) }) else { return nil }
        if let active = book.active { return .resume(active) }
        return .fresh
    }
}
