import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// That every state has its texts — and that no two have the same ones.
///
/// **The second half is the more important one.** A missing key is noticed on screen
/// immediately, because the bare key name shows there. Two states with the same sentence
/// are **never** noticed: The screen looks right, and only the viewer goes to the wrong
/// place. That is exactly what happened on the TV — "all groups hidden" and "no channels
/// set up yet" had nearly shared one sentence, and one case is solved with a switch, the
/// other is not.
///
/// Whether the keys **exist** in the catalog is checked by `scripts/strings.py` in
/// `check.sh` — that is why they are written out literally here and not assembled.
///
/// **Since AP58 R3 the table is shared in `Flows`.** These checks run unchanged against
/// it; whether every icon really resolves and every key in the shared catalog exists in
/// three languages is checked there by `StateTableTests`.
@Suite("State texts")
struct StateTextTests {

    /// The design draws eighteen, the build added three.
    ///
    /// **The twenty-fourth came on 2026-09-10 with the handoff channel** (AP5):
    /// ``PlaybackPhase/cameraDenied``. It is the only one triggered neither by catalog nor by
    /// network but by a decision of the viewer — and the only one whose way out leads out of
    /// the app, into the system settings.
    ///
    /// Stated as a number here so that a twenty-fifth does not slip in unnoticed: Every new
    /// state is a decision and not an addition.
    ///
    /// **The twentieth is ``PlaybackPhase/xtreamRawStreamOnly``** (2026-09-06), and it is exactly such a
    /// decision: The screen claimed "The one connection is busy" with **zero** active
    /// connections. Both look the same as an engine teardown and have nothing to do with each
    /// other for the viewer.
    ///
    /// **The twenty-first is ``PlaybackPhase/emptyFavorites``** (2026-09-06) — the empty case of a tab
    /// that did not exist until then: It was in the bar and had no view.
    ///
    /// **The twenty-second is ``PlaybackPhase/certificateSystemPlayer``** (2026-09-07, TestFlight):
    /// Library present, movie does not play — the system player does not trust a certificate
    /// that the app accepted. Until then that was called "no answer".
    ///
    /// **The twenty-third is ``PlaybackPhase/jellyfinWontPlay``** (2026-09-07, simulator): the same
    /// screen, a different cause. The server answers in milliseconds, and only this one file
    /// cannot be opened — `-11828` on a Matroska that could be repackaged neither in the app
    /// nor on the server. Until then this too was called "no answer from the media server" and
    /// sent the viewer to the tunnel.
    /// **The twenty-fifth is ``PlaybackPhase/networkTV``** (2026-09-10, AP8): The Apple TV does not
    /// answer the remote. **A case of its own and not ``PlaybackPhase/networkJellyfin``** — the media
    /// server is not involved in a remote, and for a channel or portal title it knows nothing
    /// about what is running over there anyway. The next step is also different: not "check
    /// your connection" but "is the TV on". An Apple TV in standby is the most common case and
    /// not one a network repairs.
    ///
    /// **The twenty-sixth is ``PlaybackPhase/xtreamAccessExpired``** (2026-09-26, AP58): The
    /// provider rejects the password. Until then this was called "Media server login expired".
    ///
    /// **Since AP58 R3 (2026-09-26) the state is shared in `Flows`**, as the union of both
    /// devices. The phone shows twenty-nine of them: its twenty-six and three that it now
    /// reaches through the shared interpretation — ``PlaybackPhase/jellyfinDisruption`` (the server
    /// answers with 404 or 500; until then this was called "No answer from Jellyfin") and the
    /// two login situations of the portals (``PlaybackPhase/portalProfileRequired``,
    /// ``PlaybackPhase/portalLoginRequired``). The three that only the TV produces are in
    /// ``PlaybackPhase/tvOnly``.
    @Test("Twenty-nine states on the phone, no more and no fewer")
    func count() {
        #expect(PlaybackPhase.onPhone.count == 29)
    }

    /// **A raw transport stream is not a busy connection.**
    ///
    /// Measured on 2026-09-06: The account allows only `ts` (`allowed_output_formats`), the
    /// `.ts` address delivers `video/mp2t`, and Apple's engine plays that only **inside** an
    /// HLS playlist. The error came as `AVFoundationErrorDomain -11850` — and the old
    /// interpretation turned it into a connection that was running elsewhere.
    @Test("The address tells a raw stream from a busy connection")
    func rawStreamInsteadOfOccupied() throws {
        let raw = try #require(URL(string: "http://beispiel.test/live/a/b/2.ts"))
        let list = try #require(URL(string: "http://beispiel.test/live/a/b/2.m3u8"))

        #expect(
            DisruptionInterpretation.state(
                forItem: PlayerModel.Dropout.motor, origin: .channelList, address: raw)
                == .xtreamRawStreamOnly)
        #expect(
            DisruptionInterpretation.state(
                forItem: PlayerModel.Dropout.motor, origin: .channelList, address: list)
                == .xtreamBusy)
        // Without an address the old interpretation stays — it was not wrong, just too quick.
        #expect(
            DisruptionInterpretation.state(forItem: PlayerModel.Dropout.motor, origin: .provider)
                == .xtreamBusy)
    }

    @Test("A job has exactly one loud button, an information none")
    func volume() {
        for state in PlaybackPhase.allCases {
            switch state.form {
            case .job(let job):
                #expect(!job.button.isEmpty)
                #expect(state.form.loudButton == job.button)
            case .info, .load, .muted:
                // **The thumb-zone rule as a check.** Only one job gets a floating bar; nothing else has
                // any business at the bottom.
                #expect(state.form.loudButton == nil)
            }
        }
    }

    @Test("Every state with texts has a headline and a sentence")
    func threeTexts() {
        for state in PlaybackPhase.allCases {
            switch state.form {
            case .info(let info):
                #expect(!info.headline.isEmpty)
                #expect(!info.message.isEmpty)
            case .job(let job):
                #expect(!job.headline.isEmpty)
                #expect(!job.message.isEmpty)
            case .load(let loading):
                #expect(!loading.message.isEmpty)
            case .muted:
                break
            }
        }
    }

    @Test("Every key belongs in the state. namespace")
    func namespace() {
        for key in Self.allKeys {
            #expect(key.hasPrefix("state."), "\(key) is outside it")
        }
    }

    /// **Four empty cases, four sentences.** No two states share a heading.
    @Test("No two states carry the same headline")
    func headingsAreOwn() {
        var seen: [String: PlaybackPhase] = [:]
        for state in PlaybackPhase.allCases {
            guard let header = Self.headline(state) else { continue }
            #expect(
                seen[header] == nil,
                "\(state.rawValue) and \(seen[header]?.rawValue ?? "") share \(header)")
            seen[header] = state
        }
    }

    /// The same rule for the sentence — with **one** named exception.
    ///
    /// ``PlaybackPhase/loadingStart`` and ``PlaybackPhase/loadingLong`` are two stages of the same waiting and
    /// may carry the same sentence; the second differs by the addition "takes longer than
    /// usual" and the way out, not by the first sentence.
    @Test("No two states carry the same sentence")
    func sentencesAreOwn() {
        var seen: [String: PlaybackPhase] = [:]
        for state in PlaybackPhase.allCases where state != .loadingLong {
            guard let message = Self.message(state) else { continue }
            #expect(
                seen[message] == nil,
                "\(state.rawValue) and \(seen[message]?.rawValue ?? "") share \(message)")
            seen[message] = state
        }
    }

    /// **Every state is reachable in the showcase.**
    ///
    /// A state whose host has no tab would not be visible in ``StateShowcase`` — and the
    /// showcase would then be a claim instead of a probe.
    @Test("Every host has a tab that the full situation carries")
    func hostsAreReachable() {
        let fullSituation = CatalogState.fromAccesses(
            jellyfin: true, channelList: true, portals: true, downloads: true, provider: true)
        for state in PlaybackPhase.allCases {
            // No `#require`: A host without a tab is not "not there" but a state that would lie above
            // the tab bar — and that would be invisible in the showcase. The message should therefore
            // say which one it is.
            guard let tab = state.host.tabs else {
                Issue.record("\(state.rawValue) sits on \(state.host.rawValue) without a tab")
                continue
            }
            // **Favorites are the one exception, and it is not a weakness of the rule but its
            // subject.** With a full setup the bar is full, and favorites move up into the header —
            // that is what `CatalogState.favoritesAtBottom` decides. Its host is therefore reachable,
            // just not as a tab. Whoever equalizes that here tests the bar and not the
            // reachability.
            if tab == .favorites {
                #expect(
                    !fullSituation.favoritesAtBottom,
                    "favorites are not a tab — then the header must carry them")
                continue
            }
            #expect(
                fullSituation.tabs.contains(tab),
                "\(state.rawValue) sits on \(tab.rawValue), which the bar does not carry")
        }
    }

    /// The cancellation is the only silent one — and it must stay silent.
    @Test("Exactly one state shows nothing")
    func exactlyOneSilent() {
        let silent = PlaybackPhase.allCases.filter { $0.form == .muted }
        #expect(silent == [.abort])
    }

    // MARK: - Helpers

    private static func headline(_ state: PlaybackPhase) -> String? {
        switch state.form {
        case .info(let info): info.headline
        case .job(let job): job.headline
        case .load, .muted: nil
        }
    }

    private static func message(_ state: PlaybackPhase) -> String? {
        switch state.form {
        case .info(let info): info.message
        case .job(let job): job.message
        case .load(let loading): loading.message
        case .muted: nil
        }
    }

    /// Every language key that the nineteen states use.
    private static var allKeys: [String] {
        PlaybackPhase.allCases.flatMap { state -> [String] in
            switch state.form {
            case .info(let a): [a.headline, a.message] + [a.sidePath].compactMap { $0 }
            case .job(let a): [a.headline, a.message, a.button] + [a.sidePath].compactMap { $0 }
            case .load(let l): [l.message] + [l.sidePath].compactMap { $0 }
            case .muted: []
            }
        }
    }
}

/// The report — **two ledgers, and until 2026-09-06 it read only one.**
///
/// The finding behind a product question: *"On tvOS the diagnostics are collected
/// automatically, and I only submit them."* That is exactly how it is built, and it has
/// long been running on the phone too — `Core` and `Playback` report at ninety-one places
/// what they do. All of that lands in `Core.TraceRecorder`; the phone's report carried
/// only `ErrorLog`, this project's own ledger.
@Suite("Report")
struct ReportTests {

    /// **Truncation is at the front and not at the back.** Jellyfin accepts client logs only up
    /// to about one megabyte; the newest part is what submitting is about.
    @Test("Truncation is at the front — the newest stays")
    func truncatesAtFront() {
        let text = (1...500).map { "Line \($0)" }.joined(separator: "\n")
        let short = ReportSending.trimmed(text, atMost: 200)

        #expect(short.contains("Line 500"), "the newest stays")
        #expect(!short.contains("Line 1\n"), "the oldest falls away")
        #expect(short.hasPrefix("… (truncated at the front"), "and it says that it was truncated")
        #expect(short.utf8.count <= 200 + 80, "the marker does not count against the limit")
    }

    /// **What fits stays untouched.** A report that carries a truncation marker without being
    /// truncated claims missing lines.
    @Test("What fits is left untouched")
    func shortEnough() {
        let text = "one line\ntwo lines"
        #expect(ReportSending.trimmed(text, atMost: 10_000) == text)
    }
}
