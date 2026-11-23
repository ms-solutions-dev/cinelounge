import CloudSync
import Core
import Foundation

/// The flow behind the pairing screens — **both directions in one state**
/// (AP44).
///
/// **Why a model at all and not a screen with a `Task` in it:** the flow is the same on
/// both devices and consists of four steps, three of which can go wrong — roll the code,
/// deposit or look, accept, clean up. A screen that does this itself is built twice, on
/// the TV and on the phone, and checked nowhere; half the cases (expired, no account,
/// cancellation in the middle of waiting) are then seen only on the device.
///
/// **The loop and the look are deliberately separate.** ``step(now:)`` is a single
/// look into the mailbox and can be checked without any time computation; ``run(spacing:)``
/// is only the repetition on top. A check that depended on a waiting time would in the
/// end check the clock.
@MainActor
@Observable
public final class PairingModel {

    /// Where the process stands — **that is also what appears on the screen.**
    public enum State: Equatable, Sendable {
        /// The code is being generated, the approval fetched.
        case isRunning
        /// The code is displayed and waits for the other device.
        case shows(code: String, until: Date)
        /// This device has taken over a profile.
        case arrived(profile: String, device: String)
        /// The other device has fetched what was deposited here.
        case pickedUp
        /// Five minutes are up without anyone coming.
        case expired
        case error(String)

        /// Whether polling is still needed.
        public var waiting: Bool {
            if case .shows = self { return true }
            return false
        }
    }

    public private(set) var state: State = .isRunning

    /// Who shows the code here — it is in the QR code and tells the other device what to do.
    public private(set) var role: Pairing.Role?

    /// When **giving**, the link the QR code carries (``ProfileLink``) — the path from
    /// StoryShelf. Then there is no code and no mailbox.
    public private(set) var profileLink: ProfileLink?

    /// Whether a scanned code is currently being processed — **the camera reports it again
    /// with every frame** (report of 2026-09-28, CKError 20). Without this latch each report
    /// started a new acceptance and overtook the running one.
    ///
    /// **Readable, because the view removes the scanner based on it** (on-device finding
    /// 2026-09-30): a profile link from the system camera starts the acceptance with `.isRunning`
    /// — the same state in which the scanner waits for a code. So during the iCloud acceptance
    /// the view showed the scanner, and the viewer scanned the same code a second time.
    public private(set) var isProcessed = false

    private let cloud: ProfileCloud
    private let device: String

    /// - Parameter geraet: the name of **this** device. It travels along and appears over
    ///   there in the feedback — "from the user's iPhone" instead of "from a device".
    public init(cloud: ProfileCloud, device: String) {
        self.cloud = cloud
        self.device = device
    }

    /// What the screen shows as a QR code — `nil` as long as there is nothing to show.
    public var qr: URL? {
        guard case .shows(let code, _) = state, let role else { return nil }
        if let profileLink { return profileLink.url }
        return Pairing.link(code: code, role: role)
    }

    /// The code for the text line under the QR code.
    public var code: String? {
        if case .shows(let code, _) = state { return code }
        return nil
    }

    // MARK: - Anfangen

    /// **Direction 1:** this device has the profile and puts it into the mailbox under a fresh
    /// code. The other one scans and fetches.
    /// Gives a profile away — **the sharing link is in the QR code itself** (``ProfileLink``, the
    /// path from StoryShelf, on-device test 2026-09-28). No code, no mailbox: whoever scans
    /// accepts directly.
    public func give(_ identifier: Profile.Identifier, title: String, now: Date = Date()) async {
        role = .give
        state = .isRunning
        do throws(CloudError) {
            let approval = try await cloud.split(identifier, title: title)
            profileLink = ProfileLink(approval: approval, person: title, device: device)
            Diagnostics.step("Profile handed out: share link as QR", since: nil, area: "Wolke")
            state = .shows(code: "", until: now.addingTimeInterval(Pairing.deadline))
        } catch {
            Diagnostics.defect(
                "Profile not shared: \(Diagnostics.explain(error))", since: nil, area: "Wolke")
            state = .error(Self.reason(error))
        }
    }

    /// **Direction 2:** this device would like a profile and shows only a code. The other
    /// one scans and deposits.
    ///
    /// **Nothing is prepared here**, and that is the difference to the other
    /// direction: a code under which nothing lies yet is not half a process but
    /// exactly what it should be — a place in the mailbox waiting for mail.
    public func search(now: Date = Date()) {
        role = .search
        state = .shows(code: Pairing.code(), until: now.addingTimeInterval(Pairing.deadline))
    }

    // MARK: - Nachsehen

    /// A single look — **the checks call it themselves.**
    public func step(now: Date = Date()) async {
        guard case .shows(let code, let until) = state, let role else { return }

        // **Look first, then check the deadline.** The other way around, a profile that arrived in
        // the last second would lose against the clock — and the viewer would see
        // "expired" although everything had been deposited.
        do throws(CloudError) {
            switch role {
            case .search:
                if let broadcast = try await cloud.fetchPairing(code: code, now: now) {
                    let profile = try await cloud.accept(broadcast.link)
                    state = .arrived(profile: profile?.name ?? "", device: broadcast.device)
                    return
                }
            case .give:
                // With the link in the QR code nothing lies in the mailbox — only the deadline counts.
                if profileLink == nil, try await cloud.pairingExists(code: code) == false {
                    state = .pickedUp
                    return
                }
            }
        } catch {
            Diagnostics.defect(
                "Pairing not checked: \(Diagnostics.explain(error))", since: nil, area: "Wolke")
            state = .error(Self.reason(error))
            return
        }

        guard now >= until else { return }
        // **Expired also means: gone.** Only the giving side has deposited anything,
        // and a key that nobody needs anymore does not belong in a public
        // database.
        if role == .give, profileLink == nil { try? await cloud.withdrawPairing(code: code) }
        state = .expired
    }

    /// The loop for `.task` — looks as long as there is something to see.
    ///
    /// - Parameter abstand: how often to ask. **Three seconds and not every one**:
    ///   it is a public database and a person who is just taking a phone out of their
    ///   pocket; asking more often speeds nothing up and earns a throttle.
    public func run(spacing: Duration = .seconds(3)) async {
        while state.waiting {
            do {
                try await Task.sleep(for: spacing)
            } catch {
                // bewusst still: `Task.sleep` throws only on cancellation — then nobody is
                // watching anymore.
                return
            }
            await step()
        }
    }

    // MARK: - The camera (phone only)

    /// What the camera has seen — **the role in the code decides what happens.**
    ///
    /// - Parameter hergibt: the profile that this device would give away if the other one
    ///   **searches**. If `nil` is there and the other device searches, the screen says so
    ///   — instead of standing still.
    /// - Returns: whether the text belonged to us. `false` means: a foreign packaging, a
    ///   Wi-Fi code — the scanner keeps running.
    @discardableResult
    public func scanned(
        _ text: String, offering: (identifier: Profile.Identifier, title: String)?,
        now: Date = Date()
    ) async -> Bool {
        guard !isProcessed else { return true }
        if case .arrived = state { return true }
        // **First the link from StoryShelf** (``ProfileLink``): it carries the approval itself.
        if let profileLink = ProfileLink(text) {
            await accept(profileLink)
            return true
        }
        isProcessed = true
        defer { isProcessed = false }
        guard let read = Pairing.read(text) else {
            // **No longer silent** (2026-09-28): "Nothing happens when scanning" had not a single
            // line in the report. What the camera saw is not in it — only that it was not a code
            // for us.
            Diagnostics.step("Camera: a code, but not one from CineLounge", since: nil, area: "Wolke")
            return false
        }
        role = read.role
        state = .isRunning

        do throws(CloudError) {
            if read.role.scannerFetches {
                guard let broadcast = try await cloud.fetchPairing(code: read.code, now: now)
                else {
                    // **Empty means expired here and not "not yet".** The displaying device
                    // deposited before displaying; whoever finds nothing sees a
                    // code whose five minutes are over — or one that someone has
                    // already fetched.
                    state = .expired
                    return true
                }
                let profile = try await cloud.accept(broadcast.link)
                state = .arrived(profile: profile?.name ?? "", device: broadcast.device)
            } else {
                guard let offering else {
                    state = .error(Self.noProfile)
                    return true
                }
                try await cloud.store(
                    offering.identifier, code: read.code, title: offering.title, device: device)
                state = .pickedUp
            }
        } catch {
            Diagnostics.defect(
                "Pairing not completed: \(Diagnostics.explain(error))", since: nil, area: "Wolke")
            state = .error(Self.reason(error))
        }
        return true
    }

    // MARK: - Cleaning up

    /// The screen closes.
    ///
    /// **A leftover entry is a valid key in a public database.** The five minutes catch it;
    /// but whoever closes the screen has already changed their mind.
    ///
    /// **In both roles, and the second is the one that gets overlooked.** Whoever *searches*
    /// has deposited nothing themselves — but under **their** code something may long be
    /// lying that they never picked up: the other device deposits as soon as it has scanned,
    /// and between depositing and the next look there are up to three seconds. Whoever closes
    /// then would leave a foreign sharing link lying open on the network. No false feedback
    /// arises from this: in this direction the giving side does not ask at all, it received
    /// its "deposited" already when scanning.
    /// Accepts a profile from a ``ProfileLink`` — from the reader in the app or from the
    /// system camera (`onOpenURL`).
    public func accept(_ profileLink: ProfileLink) async {
        guard !isProcessed else { return }
        isProcessed = true
        defer { isProcessed = false }
        role = .give
        state = .isRunning
        do throws(CloudError) {
            let profile = try await cloud.accept(profileLink.approval, fallbackName: profileLink.person)
            Diagnostics.step("Profile accepted via the profile link", since: nil, area: "Wolke")
            state = .arrived(
                profile: profile?.name ?? profileLink.person ?? "", device: profileLink.device ?? "")
        } catch {
            Diagnostics.defect(
                "Profile not accepted: \(Diagnostics.explain(error))", since: nil, area: "Wolke")
            state = .error(Self.reason(error))
        }
    }

    public func close() async {
        guard profileLink == nil, case .shows(let code, _) = state else { return }
        try? await cloud.withdrawPairing(code: code)
    }

    // MARK: - Meldungen

    /// The placeholder for "this device has no profile to give".
    ///
    /// **A key and not a sentence.** What stands here belongs in the UI's language catalog;
    /// ``ProfileKit`` has none and is not meant to get one.
    public static let noProfile = "pairing.noProfile"

    /// Why it did not work — as a key for the language catalog.
    public static func reason(_ error: CloudError) -> String {
        switch error {
        case .noAccount: "pairing.noAccount"
        case .unreachable: "pairing.offline"
        default: "pairing.failed"
        }
    }
}
