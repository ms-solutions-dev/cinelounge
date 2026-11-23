import Core
import DesignSystemPhone
import Diagnose
import Foundation
import Observation
import ParentalControls
import PlaylistKit
import ProfileKit
import SecondScreen

/// What happens during a transfer — **from the camera to the receipt.**
///
/// **The order is the whole decision of this model:** first show what goes out
/// (``CarryOverSheet``), then ask who is holding the phone (``AccessGrant``), only then pack
/// and send. The other way round — read the code, send, show the table afterwards —
/// would be consent to something that has already happened.
///
/// **Packing happens only after the approval.** A finished bundle in memory is a
/// collection of all credential tokens and passwords in one place; having it lie there
/// while someone is still thinking is unnecessary.
@MainActor
@Observable
public final class HandoffModel {

    /// Where the process stands.
    public enum Situation: Equatable {
        /// The camera is looking for a code.
        case isSearching
        /// A code has been read — now the table is shown.
        case read
        /// Face ID, Packen, Senden.
        case sending
        case done
        /// The finished sentence from ``SecondScreen/HandoffMessage`` — the cause comes from
        /// ``HandoffWire``, the wording from `WordingKit` (AP58 R5). A sentence and not a
        /// key, because it is not in the app's catalog: `Text(appKey:)` would not find it
        /// there and therefore shows it as it is.
        case failed(String)
    }

    public private(set) var state: Situation = .isSearching

    /// The key that was read — `nil` as long as the camera has found nothing.
    public private(set) var key: HandoffKey?

    private let status: SetupState
    private let backup: ParentalControlsState
    private let keychain: SecureStore
    private let listen: PlaylistStore
    private let trust: CertificateTrustStore
    private let store: UserDefaults
    /// Where the shelf order lives — since AP40 a file and not the Keychain.
    private let shelfStore: any KeyValueStore
    /// Where ``ProfileKit/ProfileBook`` lives — since AP44 it travels along.
    private let ledgerStore: any KeyValueStore
    private let approval: AccessGrant
    private let channels: HandoffSender

    public init(
        status: SetupState,
        backup: ParentalControlsState,
        keychain: SecureStore = SecureStore(),
        listen: PlaylistStore = PlaylistStore(
            store: SecureStore(), secrets: SecureStore(), ledger: FileStore()),
        trust: CertificateTrustStore = CertificateTrustStore(),
        store: UserDefaults = .standard,
        shelfStore: (any KeyValueStore)? = nil,
        ledgerStore: (any KeyValueStore)? = nil,
        approval: AccessGrant = AccessGrant(),
        channels: HandoffSender = HandoffSender()
    ) {
        self.status = status
        self.backup = backup
        self.keychain = keychain
        self.listen = listen
        self.trust = trust
        self.store = store
        self.shelfStore = shelfStore ?? FileStore()
        self.ledgerStore = ledgerStore ?? FileStore()
        self.approval = approval
        self.channels = channels
    }

    // MARK: - The path

    /// The camera has seen something.
    ///
    /// **What does not fit is silently skipped.** A camera sees
    /// packaging, posters and Wi-Fi codes; reporting each of them as a failure would mean
    /// showing an error where nothing was attempted
    /// (``HandoffKey/fromText(_:)``).
    public func read(_ text: String) {
        guard state == .isSearching, let new = HandoffKey.fromText(text) else { return }
        key = new
        state = .read
        Diagnose.step(.login, "Handoff: code read, target \(new.target)")
    }

    /// The viewer has seen the table and agreed.
    public func transfer() async {
        guard let key else { return }
        // **The code is valid for three minutes, and the table is something one reads.** Whoever
        // starts here without checking the clock sends into a connection that the TV
        // closes again immediately — and the message would be "not reachable".
        guard key.applies() else {
            notify(.failed(HandoffMessage.message(zu: .rejected(.expired), page: .channels)))
            return
        }

        switch await approval.query(reason: AppLanguageSetting.text("handover.reason")) {
        case .isAllowed, .notPossible:
            // **A device without a passcode and without biometrics may still transfer.** Otherwise
            // the handoff would be closed to exactly those who have not set up an unlock
            // method — and the QR proves proximity anyway.
            break
        case .wasCancelled:
            state = .read
            return
        }

        state = .sending
        do {
            try await channels.send(bundles(), using: key)
            state = .done
            Diagnose.step(.login, "Handoff: accepted")
        } catch let caughtError as HandoffWire.TestError {
            notify(.failed(HandoffMessage.message(zu: caughtError, page: .channels)))
            Diagnose.hint(.login, "Handoff failed: \(caughtError)")
        } catch {
            notify(.failed(HandoffMessage.message(zu: .noService, page: .channels)))
            Diagnose.hint(.login, "Handoff failed", error)
        }
    }

    /// From the start — **with a fresh camera and without the old code.**
    public func retry() {
        key = nil
        state = .isSearching
    }

    private func notify(_ incoming: Situation) {
        state = incoming
    }

    // MARK: - Was hinausgeht

    /// Packs together what ``CarryOverSheet`` lists.
    ///
    /// **The table in the sheet and this function are the same promise.** Whoever adds a
    /// field here and no row there transfers something nobody announced;
    /// whoever adds a row there and no field here promises something that does not
    /// arrive. ``HandoffContentTests`` holds both directions.
    ///
    /// **Group order, hidden groups and sports selection only since 2026-09-27**
    /// (ultra e5, round A.5). The fields existed, but were never packed — and the sheet
    /// promised the group order. They live in the Keychain under the same
    /// keys as on the TV (``Core/LivePreferences``, ``Core/SportFilterSettings``).
    func bundles() -> SetupBundle {
        SetupBundle(
            jellyfin: jellyfin(),
            channelLists: channelLists(),
            bridge: status.bridgeURL,
            omdbKey: keychain.omdbAPIKey(),
            tmdbKey: keychain.tmdbAPIKey(),
            malKey: keychain.malClientID(),
            // **The language of the active profile** (AP46) — and empty means "as the
            // system", so there is nothing to transfer.
            language: Optional(LanguageChoice.chosen(store, keychain: keychain))
                .flatMap { $0.isEmpty ? nil : $0 },
            colorPattern: ColorPattern.chosen(in: shelfStore),
            shelfOrder: shelfOrder(),
            sports: SportFilterSettings.load(from: keychain).disabled.sorted(),
            groupOrder: LivePreferences.load(from: keychain).groupOrder,
            hiddenGroups: LivePreferences.load(from: keychain).hiddenGroups.sorted(),
            parentalControls: parentalControls(),
            profile: ProfileBook.read(from: ledgerStore).profile)
    }

    /// The shelf order — **and the way it was lost until 2026-09-21** (AP40).
    ///
    /// Here stood `store.stringArray(forKey: StartPreferences.schluesselReihenfolge)`:
    /// the right key, the wrong store. The order was saved in the Keychain, as a string
    /// with line breaks — from `UserDefaults` therefore **always** came `nil`, and the bundle
    /// **never** carried an order. The sheet "What travels along" nevertheless said "Language,
    /// color scheme, shelf and group order": a promise nobody kept and nobody missed.
    ///
    /// **The same trap as with the age limit (AP22) and the bridge address** —
    /// the same name, two stores. It went unnoticed because an empty field at
    /// this spot looks like "nothing set". Now it is read with the reader that
    /// also writes, and the check for it fills the order and looks in the bundle.
    private func shelfOrder() -> [String] {
        StartPreferences.load(from: shelfStore, forItem: ProfilePointer.active).order.map(\.rawValue)
    }

    /// The media server **including certificate trust.**
    ///
    /// Without the fingerprints, the TV asks on the first connect, and someone
    /// then stands before a security question they cannot answer: they
    /// have nothing to compare against. In the home network this is the normal case and
    /// not the exception — a `.home` name carries a self-issued certificate.
    ///
    /// **Only the host of the media server** (setup check, E6, 2026-09-27). Until
    /// then **all** digests of this phone went along — including those for hosts the TV
    /// has nothing to do with. The bundle says whom the TV should trust
    /// to reach this one server, and no more.
    private func jellyfin() -> SetupBundle.ServerAccess? {
        guard let credential = status.jellyfin else { return nil }
        let calculator = credential.serverURL.host()?.lowercased()
        let digests = trust.trusted()
            .filter { $0.key.lowercased() == calculator }.mapValues(\.value)
        return .init(
            address: credential.serverURL, userID: credential.userID,
            username: credential.username, accessToken: credential.accessToken,
            trusted: digests)
    }

    /// The channel lists **including passwords** — otherwise a list arrives over there that asks
    /// for a password the viewer considered assigned.
    private func channelLists() -> [SetupBundle.ListAccess] {
        status.channelLists.compactMap { list in
            switch list.kind {
            case .xtream(let server, let user):
                .init(
                    identifier: list.id, name: list.name, address: server, user: user,
                    password: listen.password(for: list.id), epg: list.epgURL)
            case .m3u(let address):
                .init(identifier: list.id, name: list.name, address: address, epg: list.epgURL)
            case .jellyfinLiveTV:
                // **The server's channel management is not a credential of its own.** It comes
                // along with the media server; transferring it would mean laying a second
                // list over the same catalog over there.
                nil
            }
        }
    }

    /// Parental controls — **with the digest of the PIN and not its digits.**
    ///
    /// The four digits are stored nowhere; ``ParentalControls/Pin`` salts and hashes them when
    /// setting. What travels is digest **and** salt — without both the TV would check
    /// against a different value and reject the correct PIN.
    private func parentalControls() -> SetupBundle.ParentalControlsState? {
        guard let extract = backup.pinDigest else { return nil }
        return .init(
            active: backup.mode.on, pin: extract,
            ageLimit: backup.limit?.rawValue)
    }
}
