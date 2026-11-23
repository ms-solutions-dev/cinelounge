import Core
import CryptoKit
import Foundation

/// The pairing of the remote wire — **the same as for the handoff**
/// (decision 6 of 2026-09-25, AP39/AP47).
///
/// **The finding it answers:** ``RemoteReceiver`` opened bare TCP. No TLS,
/// no pairing, no check of who is speaking — whoever was on the home network could pause the
/// film, open titles and type into any open field. As long as that was so, the
/// password field must not accept the remote keyboard.
///
/// **The path, in four steps:**
///
/// 1. **Pair once.** The TV shows a QR code with a
///    ``HandoffKey`` — the same one-time key as for the handoff, only under
///    the scheme ``schema``. The phone creates a **permanent key** and sends it,
///    sealed with the one-time key, together with its identifier. Whoever has not seen the
///    screen does not know the one-time key and cannot pair. The one-time key applies for
///    three minutes and **once**.
/// 2. **Every connection starts with two random numbers.** The TV sends in the
///    greeting 32 bytes (the challenge) and its identifier, the phone in the
///    sign-in 32 of its own (the nonce). Both sides derive two session keys from the permanent key, **both**
///    numbers and the TV identifier (HKDF-SHA256, one per direction). **Because each side
///    rolls its own part, no direction can be replayed:** A recording of the greeting
///    produces different keys on the phone because of the fresh nonce, a recording of the
///    sign-in on the TV because of the fresh challenge (counter-check strand D, finding 1.3).
/// 3. **The phone proves the key before it counts.** Directly after the sign-in
///    it sends a sealed ``Proof``. Only when that can be opened is
///    the connection signed in and **only then** does it replace an older one. The identifier
///    alone is in plain text in every sign-in; whoever reads along gets as far as
///    ``RemoteSession/Situation/awaitingProof(_:)`` and no further (finding 1.1).
/// 4. **After that every frame is AES-GCM** (``WireSeal``) with a counter in it that
///    may only rise. What cannot be opened is discarded, and the connection
///    drops.
///
/// **There is a single rejection, and it always comes only after the proof.** Whether an identifier
/// is unknown, a pairing code did not apply or the proof did not hold — from
/// outside it looks the same (finding 1.5). It is **proven** only if the TV
/// once knew the phone and deliberately forgot it: Then it carries an HMAC over
/// `rejection‖challenge‖nonce` with a key derived from the permanent key, and only
/// such a rejection may delete the credential on the phone (finding 1.2). An unproven one
/// can be sent by anyone on the Wi-Fi and is a hint.
///
/// **Without TLS, for the same reason as for the handoff:** The protection lives in the content,
/// and a certificate nobody issues would be a warning someone taps away.
///
/// **Older phones.** The greeting is built so that a phone without pairing reads it
/// as an ordinary ``StateMirror`` — and shows as the "title" a sentence that
/// says what to do (``defaultHint``). It can no longer operate anything; its commands
/// arrive unencrypted and are discarded. That is intended.
public enum RemotePairing {

    /// The scheme in the pairing's QR code — **a different one from the handoff's**, so that
    /// the phone recognizes from the scan what it is about.
    public static let schema = "cinelounge-fern"

    /// The version of the pairing, as it appears in the greeting.
    ///
    /// **2 since the counter-check of strand D:** the phone's nonce, proof, proven
    /// rejection. Version 1 never went out to a phone; there is no bridge to it.
    public static let version = 2

    /// The string for phones without pairing, if the program does not supply a translated one.
    public static let defaultHint =
        "CineLounge auf dem iPhone aktualisieren und am Fernseher koppeln"

    /// At most this many paired phones — the oldest drops out.
    public static let maximumCount = 20

    /// How long challenge and nonce are.
    static let randomLength = 32

    /// What can go wrong when connecting or pairing — **every case with its advice.**
    public enum TestError: Error, Equatable, Sendable {
        /// **Proven unpaired:** This phone has no credential for the TV,
        /// or the TV said with a proven rejection that it has forgotten the pairing.
        /// **The only case in which a credential may go** —
        /// ``OwnWire`` then deletes it itself. The advice: show the
        /// pairing code on the TV.
        case unpaired
        /// **A rejection without proof.** It can come from the TV (it no longer knows the phone,
        /// for example after a reinstall) — or from anyone on the Wi-Fi. That is why it is
        /// **only a hint**: The credential stays; the UI may offer to pair again,
        /// and a new pairing then replaces it.
        case dismissed
        /// The pairing code did not apply (expired, already used, wrong) — or the
        /// TV rejected the pairing otherwise.
        case pairingRejected
        /// The TV does not greet, or greets in another version. The advice: update the app on the
        /// Apple TV.
        case tvTooOld
        /// A frame could not be opened or read.
        case unreadable
    }

    // MARK: - What goes over the wire

    /// The offer in the greeting.
    struct Offer: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case version = "fassung"
            case challenge = "herausforderung"
            case tv = "fernseher"
        }

        let version: Int
        let challenge: Data
        /// The identifier of this TV (``RemotePairingLedger/tvIdentifier``) — **the
        /// key under which the phone stores its credential**, and part of the
        /// session keys. A swapped value therefore does not lead to a foreign
        /// credential but to keys that do not fit.
        let tv: String
    }

    /// The TV's first frame, **in plain text.**
    ///
    /// **A superset of ``StateMirror``**: The mirror's mandatory fields are in
    /// it, and `title` carries the hint. A phone of an older version reads it as a
    /// mirror and shows the sentence; a new one recognizes `pairing` and pairs.
    struct Greeting: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case title = "titel"
            case location = "stelle"
            case isRunning = "laeuft"
            case keyboardOpen = "tastaturOffen"
            case keyboardText = "tastaturtext"
            case pairing = "kopplung"
        }

        var title: String?
        var location: TimeInterval = 0
        var isRunning = false
        var keyboardOpen = false
        var keyboardText = ""
        var pairing: Offer?
    }

    /// The phone's first frame, in plain text — identifier, **its own nonce** and, on
    /// the first pairing, the sealed request.
    struct SignIn: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
            case nonce
            case pairing = "kopplung"
        }

        let phone: String
        let nonce: Data
        var pairing: Data?
    }

    /// What goes across **sealed with the one-time key** on the first pairing.
    struct PairingRequest: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
            case name
            case key = "schluessel"
        }

        let phone: String
        let name: String
        let key: Data
    }

    /// The phone's second frame, **sealed** — the proof that it has the
    /// permanent key.
    ///
    /// **A type of its own and not a command**, so that a proof can never be executed as a command
    /// and no command counts as a proof.
    struct Proof: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
        }

        let phone: String
    }

    /// The TV's rejection, in plain text — after that it hangs up.
    ///
    /// **Always the same word and always 32 bytes of proof**, even when there is nothing to prove
    /// (then random). Otherwise the form alone would reveal which case applies.
    struct Rejection: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case rejection = "absage"
            case evidence = "beleg"
        }

        let rejection: String
        let evidence: Data

        static let word = "refused"
    }

    /// A rejection **without proof** — random in the place of the proof, the same form as any
    /// other (final check 2026-09-25, D2-1).
    ///
    /// For the TV that turns away a connection before greeting it: There is no
    /// challenge yet, so nothing to prove either. The phone reads it as
    /// ``TestError/dismissed``.
    static func rejectionWithoutEvidence() -> Data {
        (try? JSONEncoder().encode(Rejection(rejection: Rejection.word, evidence: random()))) ?? Data()
    }

    /// A sealed frame carries a counter — **it may only rise.**
    struct Envelope<Value: Codable & Sendable>: Codable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case n
            case value = "wert"
        }

        let n: UInt64
        let value: Value
    }

    // MARK: - Keys

    /// The two session keys of a connection.
    ///
    /// **One per direction**, so that a frame from the TV cannot be reflected back as a frame
    /// from the phone. **The salt is `challenge‖nonce`** — the
    /// TV's random number and the phone's; if one were missing, the direction whose side
    /// does not roll along could be replayed.
    struct Lane: Sendable {
        let toTV: SymmetricKey
        let toPhone: SymmetricKey

        init(permanentKey: Data, challenge: Data, nonce: Data, tv: String) {
            let material = SymmetricKey(data: permanentKey)
            func derive(_ direction: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: material, salt: challenge + nonce,
                    info: Data("cinelounge-fern-\(RemotePairing.version) \(direction) \(tv)".utf8),
                    outputByteCount: 32)
            }
            toTV = derive("telefon>fernseher")
            toPhone = derive("fernseher>telefon")
        }
    }

    /// The key with which a rejection is proven — **derived from the permanent key
    /// and not the key itself.** This way the TV can keep it for a forgotten
    /// phone without anyone ever getting in with it again.
    static func rejectionKey(_ permanentKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: permanentKey), salt: Data(),
            info: Data("cinelounge-fern-\(version) absage".utf8), outputByteCount: 32)
    }

    /// HMAC-SHA256 over `rejection‖challenge‖nonce`.
    static func evidence(_ key: SymmetricKey, challenge: Data, nonce: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(Rejection.word.utf8) + challenge + nonce, using: key))
    }

    /// Whether a rejection is proven with this permanent key — checked in constant time.
    static func taken(
        _ rejection: Rejection, permanentKey: Data, challenge: Data, nonce: Data
    ) -> Bool {
        rejection.rejection == Rejection.word
            && HMAC<SHA256>.isValidAuthenticationCode(
                rejection.evidence, authenticating: Data(Rejection.word.utf8) + challenge + nonce,
                using: rejectionKey(permanentKey))
    }

    static func seal<Value: Codable & Sendable>(
        _ value: Value, n: UInt64, using key: SymmetricKey
    ) throws -> Data {
        try WireSeal.seal(
            JSONEncoder().encode(Envelope(n: n, value: value)), using: key)
    }

    static func open<Value: Codable & Sendable>(
        _ data: Data, als: Value.Type, using key: SymmetricKey
    ) -> Envelope<Value>? {
        guard let plaintext = WireSeal.open(data, using: key) else { return nil }
        return try? JSONDecoder().decode(Envelope<Value>.self, from: plaintext)
    }

    static func random(_ count: Int = randomLength) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

// MARK: - The TV's side: paired phones

/// Which phones are paired with **this** TV — in the Keychain.
///
/// **The permanent keys are secrets**, hence in the Keychain and never in a
/// file, and no type here names them in `description`.
///
/// **Accessibility (finding 1.6, changed on 2026-09-27, AP54):** The programs store the
/// book in `SecureStore(thisDeviceOnly: true)` — `…AfterFirstUnlockThisDeviceOnly`. A
/// device backup then no longer carries the keys over to a new device, which would
/// otherwise pass itself off as the old one. `SecureStore` migrates older entries on first read.
public struct RemotePairingLedger: Sendable {

    /// A paired phone as the UI sees it — **without keys.**
    public struct Phone: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let since: Date
    }

    struct ContentEntryRecord: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
            case name
            case key = "schluessel"
            case since = "seit"
        }

        let phone: String
        let name: String
        let key: Data
        let since: Date
    }

    /// A forgotten phone — **only the rejection key left**, so that the rejection of it
    /// is proven (``RemotePairing/rejectionKey(_:)``). It can never get in with it.
    struct Forgotten: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
            case rejectionKey = "absageschluessel"
        }

        let phone: String
        let rejectionKey: Data
    }

    /// The keys in the store. **Not string keys** — the namespace does not appear in the
    /// catalog.
    static let key = "zweitschirm.fernkopplungen"
    static let forgottenKey = "zweitschirm.fernvergessen"
    static let identifierKey = "zweitschirm.fernseherkennung"

    private let store: any KeyValueStore

    /// **Every change to the lists runs under this one lock** (ultra e5, round A.3,
    /// 2026-09-27).
    ///
    /// Adding and forgetting are each a three-step — read, filter, write — over
    /// the same string in the Keychain. ``accept(_:now:)`` ran under the lock
    /// of the ``RemoteReceiver``, ``forget(_:)`` without; when both came at once, the
    /// forgetting wrote its old list over the new one, and a pairing that had just succeeded was gone.
    /// **Static and not per instance**, because the book is a value: The settings
    /// and the receiver each hold a copy over the same store, and a lock that
    /// each copy had for itself would lock nothing.
    private static let writeLock = NSLock()

    /// - Parameter ablage: In the program the Keychain; checks pass in an in-memory
    ///   store.
    public init(_ store: any KeyValueStore) {
        self.store = store
    }

    /// The identifier of this TV — **rolled once and then fixed.**
    ///
    /// The phone stores its credential under it and not under the Bonjour name:
    /// Two TVs named "Living Room" would otherwise overwrite each other, and a
    /// renamed one would be a stranger (finding 1.6).
    public var tvIdentifier: String {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        if let da = try? store.value(for: Self.identifierKey), !da.isEmpty { return da }
        let fresh = UUID().uuidString
        try? store.set(fresh, for: Self.identifierKey)
        return fresh
    }

    private func read<Value: Decodable>(_ key: String) -> [Value] {
        guard let text = try? store.value(for: key),
            let list = try? JSONDecoder().decode([Value].self, from: Data(text.utf8))
        else { return [] }
        return list
    }

    private func write<Value: Encodable>(_ list: [Value], _ key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? store.set(String(decoding: data, as: UTF8.self), for: key)
    }

    func entries() -> [ContentEntryRecord] { read(Self.key) }

    private func forgotten() -> [Forgotten] { read(Self.forgottenKey) }

    /// The paired phones, newest first.
    public var phones: [Phone] {
        entries().sorted { $0.since > $1.since }
            .map { Phone(id: $0.phone, name: $0.name, since: $0.since) }
    }

    func permanentKey(forItem phone: String) -> Data? {
        entries().first { $0.phone == phone }?.key
    }

    /// The rejection key of a **forgotten** phone, otherwise `nil`.
    func rejectionKey(forItem phone: String) -> SymmetricKey? {
        forgotten().first { $0.phone == phone }.map { SymmetricKey(data: $0.rejectionKey) }
    }

    /// Adds a phone — **replaces** an older pairing with the same identifier.
    @discardableResult
    func accept(_ request: RemotePairing.PairingRequest, now: Date = Date()) -> Phone {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        var list = entries().filter { $0.phone != request.phone }
        list.append(
            ContentEntryRecord(
                phone: request.phone, name: request.name, key: request.key,
                since: now))
        var dropped: [ContentEntryRecord] = []
        if list.count > RemotePairing.maximumCount {
            let sortedEntries = list.sorted { $0.since > $1.since }
            list = Array(sortedEntries.prefix(RemotePairing.maximumCount))
            dropped = Array(sortedEntries.dropFirst(RemotePairing.maximumCount))
        }
        write(list, Self.key)
        rememberForgotten(dropped, without: request.phone)
        return Phone(id: request.phone, name: request.name, since: now)
    }

    /// Forgets a phone — **it only gets back in with a new pairing.**
    ///
    /// Only its rejection key is kept: If it reports again, it gets a
    /// **proven** rejection and may delete its credential.
    public func forget(_ phone: String) {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let all = entries()
        write(all.filter { $0.phone != phone }, Self.key)
        rememberForgotten(all.filter { $0.phone == phone }, without: nil)
    }

    private func rememberForgotten(_ dropped: [ContentEntryRecord], without fresh: String?) {
        let route = Set(dropped.map(\.phone))
        var list = forgotten().filter { !route.contains($0.phone) && $0.phone != fresh }
        for entry in dropped {
            let key = RemotePairing.rejectionKey(entry.key)
            list.append(
                Forgotten(
                    phone: entry.phone,
                    rejectionKey: key.withUnsafeBytes { Data($0) }))
        }
        write(Array(list.suffix(RemotePairing.maximumCount)), Self.forgottenKey)
    }
}

// MARK: - The phone's side: the credential per TV

/// What a phone needs to identify itself to **one** TV.
///
/// **A secret**, hence not `Codable` to the outside and without `description`; it is stored
/// only through ``RemoteCredentialStore`` in the Keychain.
public struct RemoteCredential: Sendable, Equatable {
    /// The identifier of this phone at this TV.
    public let phone: String
    /// The identifier of the TV (from its greeting, bound at pairing) — the
    /// key in the ``RemoteCredentialStore``. Empty only before pairing.
    public let tv: String
    /// What the TV was called at pairing (Bonjour name) — **for display only.**
    public let name: String
    let key: Data

    init(phone: String, tv: String, name: String, key: Data) {
        self.phone = phone
        self.tv = tv
        self.name = name
        self.key = key
    }

    /// A fresh credential for the first pairing — not yet bound to any TV.
    static func fresh(name: String) -> RemoteCredential {
        RemoteCredential(
            phone: UUID().uuidString, tv: "", name: name,
            key: RemotePairing.random())
    }

    /// The same credential, bound to the identifier from the greeting.
    func bound(on tv: String) -> RemoteCredential {
        RemoteCredential(phone: phone, tv: tv, name: name, key: key)
    }
}

extension RemoteCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Fernausweis(\(name), •••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Where the phone stores its credentials — **one per TV identifier**, in the Keychain.
///
/// **Keyed by ``RemoteCredential/tv`` and not by the Bonjour name** (finding
/// 1.6): Two TVs with the same name would otherwise overwrite each other.
///
/// **Only whoever can prove it may delete.** ``OwnWire`` deletes a credential itself
/// when the TV answers with a proven rejection
/// (``RemotePairing/TestError/unpaired``). After ``RemotePairing/TestError/dismissed`` the
/// UI must **not** delete — the rejection can come from anyone on the Wi-Fi.
/// ``forget(tv:)`` is there for the person's explicit wish.
public struct RemoteCredentialStore: Sendable {

    static let key = "zweitschirm.fernausweise"

    private struct Image: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case phone = "telefon"
            case tv = "fernseher"
            case name
            case key = "schluessel"
        }

        let phone: String
        let tv: String
        let name: String
        let key: Data
    }

    private let store: any KeyValueStore

    public init(_ store: any KeyValueStore) {
        self.store = store
    }

    private func images() -> [Image] {
        guard let text = try? store.value(for: Self.key),
            let list = try? JSONDecoder().decode([Image].self, from: Data(text.utf8))
        else { return [] }
        return list
    }

    private func write(_ list: [Image]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? store.set(String(decoding: data, as: UTF8.self), for: Self.key)
    }

    /// All credentials — for a "paired TVs" list.
    public var all: [RemoteCredential] {
        images().map {
            RemoteCredential(
                phone: $0.phone, tv: $0.tv, name: $0.name,
                key: $0.key)
        }
    }

    /// The credential for the TV with this identifier.
    public func credential(forItem tv: String) -> RemoteCredential? {
        all.first { $0.tv == tv }
    }

    /// Stores a bound credential — **replaces** the one for the same TV.
    func create(_ credential: RemoteCredential) {
        guard !credential.tv.isEmpty else { return }
        var list = images().filter { $0.tv != credential.tv }
        list.append(
            Image(
                phone: credential.phone, tv: credential.tv, name: credential.name,
                key: credential.key))
        write(list)
    }

    /// Throw away a credential — on explicit request or after a **proven**
    /// rejection, never after an unproven one.
    public func forget(tv: String) {
        write(images().filter { $0.tv != tv })
    }
}

// MARK: - The session on the TV, without a network

/// A connection at the TV as a **calculation**: frames in, actions out.
///
/// **Without a network and therefore testable.** ``RemoteReceiver`` passes every complete frame
/// in here and does what comes out; the decision of who may speak lives in
/// exactly one place.
struct RemoteSession: Sendable {

    enum Action: Sendable {
        /// Diesen Inhalt gerahmt hinausschicken.
        case send(Data)
        /// A verified command.
        case command(Command)
        /// A phone has just been paired.
        case paired(RemotePairingLedger.Phone)
        /// **The pairing code is used up — already at sign-in** (ultra e5,
        /// round A.2, 2026-09-27). The caller throws the one-time key away **immediately**,
        /// in the same step in which it passed it in.
        ///
        /// Until then the code was only checked at sign-in and used up only with
        /// ``paired(_:)``, i.e. after the proof. Two phones that scanned the same
        /// code at the same time both got through in between and both stayed
        /// permanently paired. Now the same rule applies as for the handoff
        /// (``HandoffReceiver``): check and consume in one step. If the proof
        /// fails afterwards, the code is gone anyway — the screen puts up a new one.
        case pairingCodeConsumed
        /// **The key is proven:** This connection is from now on the phone's.
        case signedIn
        /// Auflegen.
        case close
    }

    /// What is known between sign-in and proof.
    ///
    /// `channel` is `nil` if it is already certain that it will be a rejection — **it is
    /// nevertheless answered only after the next frame**, so that a known identifier is not
    /// rejected faster than an unknown one.
    struct Check: Sendable {
        let phone: String
        let nonce: Data
        var channel: RemotePairing.Lane?
        var request: RemotePairing.PairingRequest?
        var rejectionKey: SymmetricKey?
        /// If it is already certain at sign-in that it will be a rejection, this says why.
        var reason: RejectionReason?
    }

    /// Why it was rejected — **only for the TV's log, never onto the wire.**
    ///
    /// Outwardly the rejection is a single one (finding 1.5); whoever could distinguish
    /// the reasons would have an oracle. In the log, by contrast, a report "pairing does
    /// not work" must be clarifiable without asking back (diagnostics coverage, 2026-09-27).
    enum RejectionReason: String, Sendable, Equatable {
        /// The first frame was not a sign-in — a phone of an older version or something foreign.
        case noLogin = "no sign-in (older version or foreign)"
        /// A pairing request, but there is no code (any more) on the screen.
        case noCodeOpen = "no pairing code open or already used up"
        case codeExpired = "pairing code expired"
        /// The request could not be opened with the code or did not match the sign-in.
        case codeWrong = "pairing request does not match the code"
        case unknown = "phone not paired"
        case forgotten = "phone was forgotten"
        case proofWrong = "proof does not hold"
        case frameUnreadable = "frame unreadable or counter did not rise"
    }

    enum Situation: Sendable {
        case awaitingLogin
        /// The sign-in came, **the proof not yet** — no rights yet.
        case awaitingProof(Check)
        case signedIn(RemotePairing.Lane)
        case closed
    }

    let challenge: Data
    /// The identifier of this TV (``RemotePairingLedger/tvIdentifier``).
    let tv: String
    private(set) var state: Situation = .awaitingLogin
    /// Who has signed in **and proven** — for "forget this phone".
    private(set) var phone: String?
    /// Why this connection was rejected — set on closing, for the log.
    private(set) var rejectionReason: RejectionReason?
    private var incomingCounter: UInt64 = 0
    private var outgoingCounter: UInt64 = 0

    init(challenge: Data = RemotePairing.random(), tv: String = "") {
        self.challenge = challenge
        self.tv = tv
    }

    var signedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// The first frame of this connection.
    func greeting(hint: String) -> Data {
        let greeting = RemotePairing.Greeting(
            title: hint,
            pairing: RemotePairing.Offer(
                version: RemotePairing.version, challenge: challenge,
                tv: tv))
        return (try? JSONEncoder().encode(greeting)) ?? Data()
    }

    /// A complete frame arrived.
    ///
    /// - Parameters:
    ///   - buch: The paired phones.
    ///   - kopplung: The one-time key, if a pairing code is currently on the screen
    ///     — otherwise `nil`. **It applies once:** If
    ///     ``Action/pairingCodeConsumed`` comes out, the caller must throw it
    ///     away immediately — before passing in the next frame.
    ///   - stand: What the TV is currently reporting — goes out as the confirmation.
    ///
    /// **Signed in: What cannot be opened or does not raise the counter ends the
    /// connection.** An unpaired phone, a wrong key and a repeated
    /// frame look the same, and none of them gets a second chance.
    mutating func take(
        _ content: Data, ledger: RemotePairingLedger, pairing: HandoffKey?,
        status: StateMirror, now: Date = Date()
    ) -> [Action] {
        switch state {
        case .closed:
            return []
        case .awaitingLogin:
            return signIn(content, ledger: ledger, pairing: pairing, now: now)
        case .awaitingProof(let check):
            return verify(content, check, ledger: ledger, status: status, now: now)
        case .signedIn(let channel):
            guard let envelope = RemotePairing.open(content, als: Command.self, using: channel.toTV),
                envelope.n > incomingCounter
            else {
                state = .closed
                rejectionReason = .frameUnreadable
                return [.close]
            }
            incomingCounter = envelope.n
            return [.command(envelope.value)]
        }
    }

    /// The phone's first frame.
    ///
    /// **If it is not a sign-in, it is a plaintext command** from a phone of an older
    /// version — immediate rejection, the phone already has the greeting with the sentence.
    ///
    /// **A sign-in does not yet give rights**, whatever identifier is in it; it only
    /// determines what the proof is checked with.
    ///
    /// **A valid pairing request consumes the code here** — see
    /// ``Action/pairingCodeConsumed``.
    private mutating func signIn(
        _ content: Data, ledger: RemotePairingLedger, pairing: HandoffKey?, now: Date
    ) -> [Action] {
        guard let login = try? JSONDecoder().decode(RemotePairing.SignIn.self, from: content),
            login.nonce.count == RemotePairing.randomLength
        else {
            return reject(nil, reason: .noLogin)
        }
        var check = Check(phone: login.phone, nonce: login.nonce)
        var actions: [Action] = []
        if let locked = login.pairing {
            if let pairing, pairing.applies(um: now),
                let plaintext = WireSeal.open(
                    locked, using: SymmetricKey(data: pairing.secret)),
                let request = try? JSONDecoder().decode(
                    RemotePairing.PairingRequest.self, from: plaintext),
                request.phone == login.phone, request.key.count == 32
            {
                check.request = request
                check.channel = channel(request.key, login.nonce)
                actions.append(.pairingCodeConsumed)
            } else if let pairing {
                check.reason = pairing.applies(um: now) ? .codeWrong : .codeExpired
            } else {
                check.reason = .noCodeOpen
            }
        } else if let duration = ledger.permanentKey(forItem: login.phone) {
            check.channel = channel(duration, login.nonce)
        } else {
            check.rejectionKey = ledger.rejectionKey(forItem: login.phone)
            check.reason = check.rejectionKey == nil ? .unknown : .forgotten
        }
        state = .awaitingProof(check)
        return actions
    }

    private func channel(_ duration: Data, _ nonce: Data) -> RemotePairing.Lane {
        RemotePairing.Lane(
            permanentKey: duration, challenge: challenge, nonce: nonce,
            tv: tv)
    }

    /// The second frame: **the proof.** Only here is the sign-in made — and on the first
    /// pairing only here is the entry written to the book.
    private mutating func verify(
        _ content: Data, _ check: Check, ledger: RemotePairingLedger,
        status: StateMirror, now: Date
    ) -> [Action] {
        guard let channel = check.channel,
            let envelope = RemotePairing.open(
                content, als: RemotePairing.Proof.self, using: channel.toTV),
            envelope.n > incomingCounter, envelope.value.phone == check.phone
        else {
            return reject(check, reason: check.reason ?? .proofWrong)
        }
        incomingCounter = envelope.n
        state = .signedIn(channel)
        phone = check.phone
        var actions: [Action] = []
        if let request = check.request {
            actions.append(.paired(ledger.accept(request, now: now)))
        }
        actions.append(.signedIn)
        if let confirmation = wrap(status) { actions.append(.send(confirmation)) }
        return actions
    }

    /// **The one rejection.** Proven only for a forgotten phone, otherwise with random in
    /// the place of the proof.
    private mutating func reject(_ check: Check?, reason: RejectionReason) -> [Action] {
        state = .closed
        rejectionReason = reason
        let evidence =
            check.flatMap { p in
                p.rejectionKey.map {
                    RemotePairing.evidence($0, challenge: challenge, nonce: p.nonce)
                }
            } ?? RemotePairing.random()
        let content =
            (try? JSONEncoder().encode(
                RemotePairing.Rejection(rejection: RemotePairing.Rejection.word, evidence: evidence)))
            ?? Data()
        return [.send(content), .close]
    }

    /// A state for the phone — **only to a signed-in connection**, otherwise `nil`.
    mutating func wrap(_ status: StateMirror) -> Data? {
        guard case .signedIn(let channel) = state else { return nil }
        outgoingCounter += 1
        return try? RemotePairing.seal(status, n: outgoingCounter, using: channel.toPhone)
    }
}

// MARK: - The sign-in on the phone, without a network

/// The phone's side as a **calculation** — counterpart to ``RemoteSession``.
struct RemoteLogin: Sendable {

    enum Event: Sendable, Equatable {
        /// Diesen Inhalt gerahmt hinausschicken.
        case send(Data)
        /// The sign-in holds; on the first time that also confirms the pairing. The
        /// credential is bound to the TV's identifier and is to be stored that way.
        case confirmed(RemoteCredential)
        case state(StateMirror)
    }

    struct Waiting: Sendable {
        let channel: RemotePairing.Lane
        let credential: RemoteCredential
        let challenge: Data
    }

    enum Situation: Sendable {
        case awaitingGreeting
        case awaitingConfirmation(Waiting)
        case signedIn(RemotePairing.Lane)
    }

    /// Where the credential for a TV identifier is stored.
    private let credentials: @Sendable (String) -> RemoteCredential?
    /// The fresh credential — only on the first pairing.
    private let newCredential: RemoteCredential?
    /// The one-time key from the QR code — only on the first pairing.
    let pairing: HandoffKey?
    let phoneName: String
    /// This phone's random number for **this** connection.
    let nonce: Data
    private(set) var state: Situation = .awaitingGreeting
    /// The TV's identifier from its greeting.
    private(set) var tv: String?
    private var incomingCounter: UInt64 = 0
    private var outgoingCounter: UInt64 = 0

    /// With a fixed credential — on pairing the fresh one, otherwise one that applies to every
    /// TV (this is how the checks calculate).
    ///
    /// - Parameter vorhandene: **Only when pairing:** where an older credential for the same
    ///   TV may be stored. Its phone identifier continues to be used — see
    ///   ``take(_:)``.
    init(
        credential: RemoteCredential?, pairing: HandoffKey? = nil, phoneName: String,
        nonce: Data = RemotePairing.random(), existing: RemoteCredentialStore? = nil
    ) {
        self.pairing = pairing
        self.phoneName = phoneName
        self.nonce = nonce
        if pairing != nil {
            newCredential = credential
            credentials = { existing?.credential(forItem: $0) }
        } else {
            newCredential = nil
            credentials = { _ in credential }
        }
    }

    /// With the store — the credential is looked up by the identifier in the greeting.
    init(credentials store: RemoteCredentialStore?, phoneName: String) {
        self.pairing = nil
        self.phoneName = phoneName
        self.nonce = RemotePairing.random()
        newCredential = nil
        credentials = { store?.credential(forItem: $0) }
    }

    var greeted: Bool {
        if case .awaitingGreeting = state { return false }
        return true
    }

    /// A frame from the TV.
    ///
    /// **A first frame without an offer comes from a TV without pairing** —
    /// ``RemotePairing/TestError/tvTooOld``. Without a credential there is no sign-in at all:
    /// ``RemotePairing/TestError/unpaired``. In response to the greeting **two** frames
    /// go out: the sign-in and right behind it the proof.
    mutating func take(_ content: Data) throws(RemotePairing.TestError) -> [Event] {
        switch state {
        case .awaitingGreeting:
            // **A rejection instead of a greeting means: no room** (final check
            // 2026-09-25, D2-1). Until then the TV hung up wordlessly, and the
            // phone guessed it should update the app on the Apple TV. Unproven — there was no
            // challenge yet —, hence ``RemotePairing/TestError/dismissed``, also when
            // pairing: The code is not consumed in that case and applies on the next attempt.
            if (try? JSONDecoder().decode(RemotePairing.Rejection.self, from: content)) != nil {
                throw .dismissed
            }
            guard let greeting = try? JSONDecoder().decode(RemotePairing.Greeting.self, from: content),
                let offer = greeting.pairing
            else {
                throw .tvTooOld
            }
            guard offer.version == RemotePairing.version else { throw .tvTooOld }
            guard offer.challenge.count == RemotePairing.randomLength else {
                throw .unreadable
            }
            tv = offer.tv
            let credential: RemoteCredential
            if pairing != nil {
                // **Re-pairing keeps the phone identifier** (setup check, side finding,
                // 2026-09-27). Every pairing rolled a new one, and the TV then kept
                // "iPhone", "iPhone", … up to the maximum — its book replaces only
                // an entry with the **same** identifier (``RemotePairingLedger/accept(_:now:)``).
                // Only the greeting says which TV it is; the key is
                // new nonetheless, only the name in the book stays the same.
                guard let fresh = newCredential else { throw .unpaired }
                let identifier = credentials(offer.tv)?.phone ?? fresh.phone
                credential = RemoteCredential(
                    phone: identifier, tv: offer.tv, name: fresh.name,
                    key: fresh.key)
            } else {
                guard let da = credentials(offer.tv) else { throw .unpaired }
                credential = da
            }
            var login = RemotePairing.SignIn(phone: credential.phone, nonce: nonce)
            if let pairing {
                let request = RemotePairing.PairingRequest(
                    phone: credential.phone, name: phoneName, key: credential.key)
                guard let plaintext = try? JSONEncoder().encode(request),
                    let zu = try? WireSeal.seal(
                        plaintext, using: SymmetricKey(data: pairing.secret))
                else { throw .unreadable }
                login.pairing = zu
            }
            let channel = RemotePairing.Lane(
                permanentKey: credential.key, challenge: offer.challenge,
                nonce: nonce, tv: offer.tv)
            outgoingCounter += 1
            guard let frame = try? JSONEncoder().encode(login),
                let proof = try? RemotePairing.seal(
                    RemotePairing.Proof(phone: credential.phone), n: outgoingCounter,
                    using: channel.toTV)
            else { throw .unreadable }
            state = .awaitingConfirmation(
                Waiting(channel: channel, credential: credential, challenge: offer.challenge))
            return [.send(frame), .send(proof)]
        case .awaitingConfirmation(let waiting):
            if let rejection = try? JSONDecoder().decode(RemotePairing.Rejection.self, from: content) {
                throw interpret(rejection, waiting)
            }
            let status = try open(content, waiting.channel)
            state = .signedIn(waiting.channel)
            return [.confirmed(waiting.credential), .state(status)]
        case .signedIn(let channel):
            return [.state(try open(content, channel))]
        }
    }

    /// What a rejection means. **Only proven does it mean "unpaired"** — and only then may
    /// the credential go.
    private func interpret(
        _ rejection: RemotePairing.Rejection, _ waiting: Waiting
    ) -> RemotePairing.TestError {
        if pairing != nil { return .pairingRejected }
        return RemotePairing.taken(
            rejection, permanentKey: waiting.credential.key,
            challenge: waiting.challenge, nonce: nonce)
            ? .unpaired : .dismissed
    }

    private mutating func open(
        _ content: Data, _ channel: RemotePairing.Lane
    ) throws(RemotePairing.TestError) -> StateMirror {
        guard
            let envelope = RemotePairing.open(
                content, als: StateMirror.self, using: channel.toPhone),
            envelope.n > incomingCounter
        else { throw .unreadable }
        incomingCounter = envelope.n
        return envelope.value
    }

    mutating func wrap(_ command: Command) throws(RemotePairing.TestError) -> Data {
        guard case .signedIn(let channel) = state else { throw .unpaired }
        outgoingCounter += 1
        guard let zu = try? RemotePairing.seal(command, n: outgoingCounter, using: channel.toTV)
        else { throw .unreadable }
        return zu
    }
}
