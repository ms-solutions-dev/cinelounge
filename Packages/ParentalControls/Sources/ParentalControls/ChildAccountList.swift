import Core
import Foundation

/// Which accounts are child accounts — **once for both programs.**
///
/// **The finding of 2026-09-19** (AP40): this type existed twice, named the same, with three
/// differences — the TV stored the list in the **Keychain** under `accounts.children`, the
/// phone in **`UserDefaults`** under `accounts.children`. Both versions carried a
/// justification, and **the phone's was the right one:** "Storing an attribute in the
/// Keychain that nobody needs to protect turns the Keychain into a junk room." The marker is
/// no secret. What locks is the PIN.
///
/// **So neither the one nor the other, but the rule** (`README.md`, "Where a setting
/// belongs"): structure belongs in a file — ``Core/FileStore``. That makes it, for the
/// first time, the *same* list in the *same* place, and the handoff can carry it without
/// translating.
///
/// **It takes strings and no `Account` type.** That type exists separately in both programs
/// (`Features` and `FeaturesPhone`), and this package is logic-only; it should know no UI
/// models. Both sides pass in `account.stored` — the same format, `"server|user"`,
/// re-checked on 2026-09-20 on both sides.
///
/// **It is expressly not a protection.** Whoever takes the app apart finds the file and can
/// rewrite it. What it provides is the mapping.
public struct ChildAccountList: Sendable {

    static let storeKey = "accounts.children"

    /// The places where the list lived before 20.09.2026 — only for taking over.
    ///
    /// **The TV's Keychain entry and the phone's `UserDefaults` entry**, in this order. They do
    /// not exclude each other: a device on which both programs ran has both — and whoever set a
    /// child account on either of them should keep it.
    static let oldKeyTV = "konten.kinder"

    private let store: any KeyValueStore

    /// - Parameter store: In operation ``Core/FileStore``; for tests `InMemoryStore`.
    public init(store: any KeyValueStore = FileStore()) {
        self.store = store
    }

    private func remembered() -> Set<String> {
        guard let json = try? store.value(for: Self.storeKey),
            let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    public func isChild(_ identifier: String) -> Bool {
        remembered().contains(identifier)
    }

    /// All remembered markers.
    ///
    /// **For the takeover into profiles** (AP41): it does not ask "is this one?", but needs
    /// the whole list at once — it knows the accounts, not their markers. That the list is
    /// otherwise read only via ``isChild(_:)`` remains correct: every call site that looks
    /// through it itself can be wrong about the shape of the marker.
    public func all() -> Set<String> {
        remembered()
    }

    /// Sets or deletes the marker.
    ///
    /// **Deleting here really means deleting and not "setting to false".** A list that keeps
    /// every account ever seen with a boolean grows with every removed account — and after a
    /// year carries entries to which there is no access any more.
    public func set(kind: Bool, forItem identifier: String) {
        var list = remembered()
        if kind { list.insert(identifier) } else { list.remove(identifier) }
        write(list)
    }

    /// Brings over a list from before 20.09.2026 — **from both old places, and only if
    /// nothing is stored yet at the new one.**
    ///
    /// - Parameters:
    ///   - schluesselbund: the TV's old place (`accounts.children`).
    ///   - ablage: the phone's old place (`accounts.children` in `UserDefaults`).
    ///
    /// **Merged and not "first one wins".** Whoever used both programs may have marked a
    /// different account on each device; discarding one of the two lists would mean silently
    /// lifting a parental control. The union is the more cautious answer when in doubt — it
    /// locks too much rather than too little.
    public func adoptOldLists(
        keychain: (any KeyValueStore)? = nil, store storeRef: UserDefaults? = nil
    ) {
        guard (try? store.value(for: Self.storeKey)) == nil else { return }

        var combined = Set<String>()
        if let json = try? keychain?.value(for: Self.oldKeyTV),
            let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode([String].self, from: data)
        {
            combined.formUnion(list)
        }
        combined.formUnion(storeRef?.stringArray(forKey: Self.storeKey) ?? [])

        guard !combined.isEmpty else { return }
        write(combined)
    }

    /// Clears the old places — **only what demonstrably stands at the new one** (AP48, decision
    /// 2 of 2026-09-25: clean cut).
    ///
    /// **What is checked is the set, not the fact that a takeover happened.** The list at the
    /// new place must contain every marker of the old one; if even one is missing (because the
    /// old place was written to after the takeover, or because writing to the new one failed),
    /// the old one stays. A deleted child marker is a lifted parental control, and nobody
    /// notices that. An empty old list carries nothing and goes — even if there is none yet at
    /// the new place.
    ///
    /// **An unreadable old entry stays.** It was never taken over; deleting it would mean
    /// throwing away something nobody has looked at.
    ///
    /// The question of *whether* clearing is allowed is answered by the caller — on the TV only
    /// once the takeover into the profile is in place.
    ///
    /// - Returns: the cleared keys, for the check and the trace.
    @discardableResult
    public func clearOldLists(
        keychain: (any KeyValueStore)? = nil, store: UserDefaults? = nil
    ) -> [String] {
        let fresh = remembered()
        var cleaned: [String] = []

        if let keychain,
            let json = try? keychain.value(for: Self.oldKeyTV),
            let data = json.data(using: .utf8),
            let old = try? JSONDecoder().decode([String].self, from: data),
            Set(old).isSubset(of: fresh)
        {
            try? keychain.remove(Self.oldKeyTV)
            cleaned.append(Self.oldKeyTV)
        }

        if let store, let old = store.stringArray(forKey: Self.storeKey),
            Set(old).isSubset(of: fresh)
        {
            store.removeObject(forKey: Self.storeKey)
            cleaned.append("UserDefaults:" + Self.storeKey)
        }
        return cleaned
    }

    private func write(_ list: Set<String>) {
        guard let data = try? JSONEncoder().encode(list.sorted()),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? store.set(json, for: Self.storeKey)
    }
}
