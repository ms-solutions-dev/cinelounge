import Core
import Foundation

/// How a device's state becomes that of its signed-in profile.
///
/// **The counterpart to ``ProfileShelves``, with the opposite rule.** There *every*
/// profile gets the device's arrangement, because a shelf order takes nothing from anyone.
/// Here **exactly one** gets it — and that is the whole purpose of AP42: a state is
/// the opposite of harmless. Everyone getting it would mean putting the adults' half-watched films
/// under "Continue Watching" for the child, that is, restoring exactly the finding for
/// whose sake the watch ledger was built.
///
/// **The signed-in profile is the active one.** ``ProfileBook/adopt(jellyfin:children:channelLists:wantsPortals:signedIn:fallbackName:in:)``
/// sets it at creation to the person the signed-in session belongs to — and exactly that person
/// was sitting in front of the TV when the old state arose.
///
/// **The device base stays.** It is the state before the first setup; as long as
/// ``ProfileBook`` is empty, the app keeps reading it.
public enum ProfileStates {

    /// Gives the signed-in profile the device's state — **once.**
    ///
    /// - Returns: Whether anything was taken over.
    @discardableResult
    public static func adopt(_ ledger: ProfileBook, store: any KeyValueStore) -> Bool {
        guard let person = ledger.activeProfile else { return false }

        let deviceState = StillLedger.read(from: store)
        guard deviceState != StillLedger() else { return false }

        // **Only where nothing stands yet.** A second takeover must not replace a state that
        // has grown in the meantime with the device's old one.
        let identifier = person.identifier.rawValue
        guard StillLedger.read(from: store, forItem: identifier) == StillLedger() else { return false }

        deviceState.write(in: store, forItem: identifier)
        return true
    }
}
