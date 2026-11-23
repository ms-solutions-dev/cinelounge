import CloudSync
import Core
import Foundation

/// What makes up a profile and lies **as a file** on the device — Home screen and channel
/// history —, synced via the cloud.
///
/// **The finding (on-device test 2026-09-28):** after taking over the profile, the Home
/// screen looked different on the phone than on the TV, and "Continue Watching" showed
/// other channels. The shelf order (`shelves.<profile>`) and the channel history
/// (`live.recentChannels.<profile>`) never went into the cloud — only a profile move on
/// the same device took them along.
///
/// **As a ``PreferenceMapping`` set and not as a new type.** A new record type has to be
/// promoted to "Production" in the CloudKit console first, otherwise the server rejects it
/// — and TestFlight writes there. `Profilvorzug` already exists, is never cleaned up, and
/// an older version skips a key it does not know.
///
/// **The shelf order: the newer state wins.** It is a deliberate action taken in one go.
/// **The channel history is merged:** per channel the latest timestamp — otherwise the
/// device that wrote last would displace the other's channels.
///
/// **A fresh profile has no record and gets none.** If the file does not exist, nothing
/// goes up; and what is missing is not created.
enum DocumentPreference {

    static let shelfOrder = "dokument.regalordnung"
    static let channelHistory = "dokument.senderverlauf"
    static let all: Set<String> = [shelfOrder, channelHistory]

    /// The store key per preference — **the same as** `Core/ShelfOrder.key` and
    /// `Flows/ChannelHistory.key` (checked there, see `DocumentPreferenceTests`).
    static let slots: [String: String] = [
        shelfOrder: ShelfOrder.key,
        channelHistory: "live.recentChannels",
    ]

    /// This many channels the history holds (`Flows/ChannelHistory.length`).
    static let historyLength = 8

    /// The rule for `Profilvorzug` — **the channel history is merged, everything else:
    /// the newer change.**
    ///
    /// **The finding (Fable, 2026-09-28):** if TV and phone each wrote a channel in quick
    /// succession, the newer writer won the conflict, and the other's channel was gone — what
    /// played on the phone was missing on the TV. The entries carry their timestamp; merging
    /// works as with downloading (``merge(here:top:)``).
    static let rule = MergeRule { own, server in
        // **The order by its state** — when the person chose it, not when a device synced
        // (2026-09-29).
        if own.name == shelfOrder {
            return MergeRule.greaterValue(stateField).merge(own, server)
        }
        var winner = MergeRule.newer.merge(own, server)
        guard own.name == channelHistory,
            let here = own[PreferenceMapping.valueField]?.text,
            let top = server[PreferenceMapping.valueField]?.text,
            let combined = merge(here: here, top: top)
        else { return winner }
        winner[PreferenceMapping.valueField] = .text(combined)
        return winner
    }

    /// Put the channel history of a disappearing profile into that of the remaining one —
    /// merged and not replaced (``ProfileMove``).
    static func moveChannelHistory(from leaving: String, after remains: String, in store: any KeyValueStore) {
        guard let bucket = slots[channelHistory] else { return }
        let old = ProfileStore.bucket(bucket, forItem: leaving)
        guard let text = try? store.value(for: old), !text.isEmpty else { return }
        adopt([channelHistory: text], in: store, forItem: remains)
        try? store.remove(old)
    }

    /// What files this profile has — raw, as they sit in the store.
    // MARK: - Wer gewinnt: der Stand

    /// **When the person last changed a document** — as a field in the record.
    ///
    /// **The finding (2026-09-29, Fable analysis):** the Home screen order went up with the
    /// time of the *sync*; the comparison state lived only in memory. After every start the
    /// own file "differed" and prevailed as the newest — whoever started last won, not whoever
    /// chose last. The CL-Server folders from the TV disappeared this way under the phone's
    /// older order.
    ///
    /// Now the record carries its state, only a newer one goes up, only a newer one comes down,
    /// and in a conflict ``rule`` decides afterwards.
    static let stateField = "stand"

    static func syncedSlot(_ preference: String, forItem profile: String) -> String {
        ProfileStore.bucket("abgeglichen." + preference, forItem: profile)
    }

    static func syncedStateSlot(_ preference: String, forItem profile: String) -> String {
        ProfileStore.bucket("abgeglichen.stand." + preference, forItem: profile)
    }

    static func rememberSynced(
        _ preference: String, _ text: String, state: Date, in store: any KeyValueStore,
        forItem profile: String
    ) {
        try? store.set(text, for: syncedSlot(preference, forItem: profile))
        try? store.set(
            String(state.timeIntervalSince1970), for: syncedStateSlot(preference, forItem: profile))
    }

    /// The state of the document on this device.
    ///
    /// - Unchanged since the last sync: the one noted then.
    /// - Changed, or never synced: when the file was written; without a file
    ///   time (test store) `now` on a change, otherwise "never".
    static func localState(
        _ preference: String, _ text: String, in store: any KeyValueStore, forItem profile: String,
        now: Date
    ) -> Date {
        let then = try? store.value(for: syncedSlot(preference, forItem: profile))
        if then == text,
            let raw = try? store.value(for: syncedStateSlot(preference, forItem: profile)),
            let seconds = TimeInterval(raw)
        {
            return Date(timeIntervalSince1970: seconds)
        }
        let fileTime = slots[preference].flatMap { bucket in
            (store as? FileStore)?.changed(ProfileStore.bucket(bucket, forItem: profile))
        }
        if let fileTime { return fileTime }
        return then == nil ? .distantPast : now
    }

    /// The state of a record up there — a record from the time before carries none and counts as
    /// "never": a file with a timestamp beats it.
    static func state(from message: CloudRecord) -> Date {
        message[stateField]?.date ?? .distantPast
    }

    /// The document records for ``ProfileCloud/upload(_:now:onlyNew:)``.
    ///
    /// - If the own state is newer than the upper one (or nothing is up there): the own one.
    /// - Otherwise **the upper one, unchanged** — nothing is written, ``ProfileCloud/download(_:)``
    ///   fetches it.
    /// - **If the file is missing here, the upper one stays.** A record that is missing from the
    ///   list is deleted on sync — a device without its own Home screen would thus delete the
    ///   TV's order from the cloud.
    static func wordings(
        here: [String: String], top: (String) -> CloudRecord?,
        store: any KeyValueStore, forItem profile: String, now: Date
    ) -> [CloudRecord] {
        var wordings: [CloudRecord] = []
        for preference in all.sorted() {
            let topRecord = top(preference)
            guard let text = here[preference] else {
                if let topRecord { wordings.append(topRecord) }
                continue
            }
            let ownState = localState(preference, text, in: store, forItem: profile, now: now)
            if let topRecord {
                let equal = topRecord[PreferenceMapping.valueField]?.text == text
                if equal || state(from: topRecord) >= ownState {
                    if equal {
                        rememberSynced(
                            preference, text, state: max(state(from: topRecord), ownState),
                            in: store, forItem: profile)
                    }
                    wordings.append(topRecord)
                    continue
                }
            }
            wordings.append(
                CloudRecord(
                    contentType: PreferenceMapping.contentType, name: preference,
                    fields: [
                        PreferenceMapping.valueField: .text(text), stateField: .date(ownState),
                    ], changed: now))
            rememberSynced(preference, text, state: ownState, in: store, forItem: profile)
        }
        return wordings
    }

    /// What is taken over from above: the channel history always (it is merged), the order
    /// only if its state is newer than the local one.
    static func fromTop(
        _ wordings: [CloudRecord], store: any KeyValueStore, forItem profile: String, now: Date
    ) -> [(preference: String, text: String, state: Date)] {
        let here = values(from: store, forItem: profile)
        return wordings.compactMap { message in
            guard message.contentType == PreferenceMapping.contentType, all.contains(message.name),
                let text = message[PreferenceMapping.valueField]?.text, here[message.name] != text
            else { return nil }
            let topState = state(from: message)
            if message.name != channelHistory, let own = here[message.name],
                // On a tie the one above wins — two devices without a timestamp agree that way.
                topState < localState(message.name, own, in: store, forItem: profile, now: now)
            {
                return nil
            }
            return (message.name, text, topState)
        }
    }

    static func values(from store: any KeyValueStore, forItem profile: String) -> [String: String] {
        var values: [String: String] = [:]
        for (preference, bucket) in slots {
            if let text = try? store.value(for: ProfileStore.bucket(bucket, forItem: profile)), !text.isEmpty
            {
                values[preference] = text
            }
        }
        return values
    }

    /// Takes over what came from above. - Returns: whether anything changed on the device.
    @discardableResult
    static func adopt(_ top: [String: String], in store: any KeyValueStore, forItem profile: String) -> Bool {
        var changed = false
        for (preference, text) in top {
            guard let bucket = slots[preference] else { continue }
            let key = ProfileStore.bucket(bucket, forItem: profile)
            let here = try? store.value(for: key)
            let fresh = preference == channelHistory ? merge(here: here, top: text) : text
            guard let fresh, fresh != here else { continue }
            try? store.set(fresh, for: key)
            changed = true
        }
        return changed
    }

    /// An entry of the channel history — the same form as `Flows/ChannelHistory.ContentEntryRecord`.
    struct HistoryEntry: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case name
            case timestamp = "zeitpunkt"
            case forgotten = "vergessen"
        }

        let name: String
        let timestamp: Date?
        /// The tombstone from `Flows/ChannelHistory/forget(_:)`.
        var forgotten: Date? = nil

        /// The newer of the two actions — remembered or forgotten.
        var action: Date { max(timestamp ?? .distantPast, forgotten ?? .distantPast) }
    }

    /// Per channel the latest action, newest first, at most ``historyLength``.
    ///
    /// **Forgetting counts like remembering** (2026-09-29): whoever removes a channel from
    /// "Continue Watching" leaves a tombstone with a timestamp; an older dated entry from the
    /// other device does not bring it back, a newer one does.
    static func merge(here: String?, top: String) -> String? {
        let reader = JSONDecoder()
        guard let remote = try? reader.decode([HistoryEntry].self, from: Data(top.utf8)) else {
            return nil
        }
        let local = here.flatMap { try? reader.decode([HistoryEntry].self, from: Data($0.utf8)) } ?? []
        var perName: [String: HistoryEntry] = [:]
        for entry in local + remote {
            if let da = perName[entry.name], da.action >= entry.action {
                continue
            }
            perName[entry.name] = entry
        }
        let ordered = perName.values.sorted { ($0.action, $1.name) > ($1.action, $0.name) }
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? writer.encode(Array(ordered.prefix(historyLength))) else { return nil }
        return String(data: raw, encoding: .utf8)
    }
}
