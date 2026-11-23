import Core
import Foundation

extension ProfileBook {

    /// Turns what lies on this device into profiles — **once.**
    ///
    /// **The "done when" condition of AP41:** a device with "two accounts, one child,
    /// two lists, one server person" yields at the first launch **without asking** two
    /// profiles, and the switcher shows both. A setup that starts again from zero
    /// after an update is the most expensive complaint there is — on tvOS
    /// typing is the most expensive operation.
    ///
    /// **If a book already exists, nothing happens.** The same rule as with all
    /// takeovers from AP40: whoever overwrites takes away from the viewer at the second launch
    /// what they set after the first.
    ///
    /// **The channel lists go to the adults and not to the child — and that is
    /// a change and not a takeover.** Until here a list hung off the **device**: it
    /// applied to everyone who sat in front, and a child account saw the same 7,746 channels as
    /// the adults. Exactly that is the reason this package came into being; the
    /// takeover would be the wrong place to carry it on for one more version. Whoever
    /// wants to give the child channels gives them — visibly, in one place, with a PIN
    /// in front.
    ///
    /// **Without a media server account a profile is created anyway.** A device that knows only
    /// channel lists is set up; a book without a profile would mean offering it the
    /// setup once more. The caller hands in the name — an
    /// invented text at this point would be a language key in the model.
    ///
    /// - Parameters:
    ///   - medienserver: The accesses from the old account list, in their order.
    ///   - kinder: The markers of the child accounts (`server|user`), as
    ///     ``ParentalControls/ChildAccountList`` keeps them.
    ///   - senderlisten: The identifiers of the lists that are set up.
    ///   - portalperson: The household person at the CineLounge server (`setup.deviceProfile`).
    ///     **It lay on the device and goes to the adults** — it never belonged to a
    ///     particular human, and whom it belongs to in the future is decided by the profile choice
    ///     and not by a takeover.
    ///   - angemeldet: The marker of the most recently signed-in account — the active
    ///     profile is made from it. If it is unknown, it stays with the first.
    /// - Returns: Whether anything was taken over. For the check, not for operation.
    @discardableResult
    public static func adopt(
        jellyfin: [Access],
        children: Set<String> = [],
        channelLists: [String] = [],
        wantsPortals: Bool = false,
        portalPerson: String? = nil,
        signedIn: String? = nil,
        fallbackName: String,
        version: String,
        in store: any KeyValueStore
    ) -> Bool {
        guard (try? store.value(for: key)) == nil else { return false }
        guard !jellyfin.isEmpty || !channelLists.isEmpty || wantsPortals else { return false }

        var ledger = ProfileBook()

        if jellyfin.isEmpty {
            var person = Profile(name: fallbackName)
            for list in channelLists { person.create(.channelList(identifier: list)) }
            if wantsPortals { person.create(.portals(person: portalPerson)) }
            ledger.create(person)
        } else {
            for credential in jellyfin {
                let tag = credential.legacyAccountID
                let isChild = tag.map(children.contains) ?? false
                var person = Profile(
                    name: credential.displayName ?? fallbackName,
                    color: Profile.ColorTag.allCases[
                        ledger.profile.count % Profile.ColorTag.allCases.count],
                    kind: isChild ? .kind : .adult)
                person.create(credential)
                if !isChild {
                    for list in channelLists { person.create(.channelList(identifier: list)) }
                    if wantsPortals { person.create(.portals(person: portalPerson)) }
                }
                ledger.create(person)
            }
            if let signedIn,
                let match = ledger.profile.first(where: {
                    $0.jellyfin?.legacyAccountID == signedIn
                })
            {
                ledger.switchTo(zu: match.identifier)
            }
        }

        ledger.write(in: store)
        // **Read back first, then count as done** — the device finding of
        // 2026-08-16 (`9554c73`): on the Apple TV a store was silently swallowed.
        // If nothing arrives, the next launch tries again instead of continuing with an empty
        // book.
        guard !ProfileBook.read(from: store).profile.isEmpty else { return false }
        memorize(version: version, in: store)
        return true
    }

    /// The key under which it is stored **when** the takeover happened.
    public static let versionKey = "profiles.takeoverVersion"

    /// Records in which app version the takeover ran.
    ///
    /// **Without this entry the condition from AP48 cannot be checked.** The package's
    /// header text says: old keys stay "readable for one version so that a rollback
    /// is possible — deleted in the one after next". *After next of what?* Until today
    /// nobody noted in which version the takeover happened; the question "have two
    /// versions passed?" thus had no reference point.
    ///
    /// **It is never overwritten, and that is the core.** If the running version were written here
    /// on every launch, the distance would always be zero and the time to clean up
    /// would never come. That is why only the takeover itself writes, and it runs exactly once
    /// (`guard` at the start of ``adopt(jellyfin:…)``).
    ///
    /// **Since 2026-09-25 cleanup happens at once and not after versions** (decision 2:
    /// clean cut) — see ``takeoverPending(in:)``. The note stays as information on
    /// when a device took over.
    static func memorize(version: String, in store: any KeyValueStore) {
        guard (try? store.value(for: versionKey)) == nil else { return }
        try? store.set(version, for: versionKey)
    }

    /// Whether the takeover into the profile **holds** — the condition under which the old keys
    /// are cleared (AP48, decision 2 of 2026-09-25: clean cut).
    ///
    /// **What is asked is the result and not the call.** ``adopt(jellyfin:…)``
    /// reports `true` only the very first time; a device that has already taken over with an earlier
    /// version would never get to clearing via the return value. And a "taken over"
    /// marker would be a second truth that lay beside the point at the first failure.
    ///
    /// **Two conditions:** a profile is in the book (read back, not remembered),
    /// and the device's state has reached a profile — if the device base is empty, there was
    /// none; otherwise at least one profile must carry a watch ledger. As long as
    /// ``ProfileStates/adopt(_:store:)`` has not run, everything stays.
    public static func takeoverPending(in store: any KeyValueStore) -> Bool {
        let ledger = ProfileBook.read(from: store)
        guard !ledger.profile.isEmpty else { return false }
        guard StillLedger.read(from: store) != StillLedger() else { return true }
        return ledger.profile.contains {
            StillLedger.read(from: store, forItem: $0.identifier.rawValue) != StillLedger()
        }
    }

    /// The version in which the takeover happened — `nil` if it never happened.
    public static func takeoverVersion(from store: any KeyValueStore) -> String? {
        try? store.value(for: versionKey)
    }
}
