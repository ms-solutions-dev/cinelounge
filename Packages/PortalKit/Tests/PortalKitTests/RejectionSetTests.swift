import Foundation
import SourceProbe
import Testing

@testable import PortalKit

/// **Every refusal that PortalKit can deliver has its sentence in the shared catalog** (review
/// 2026-09-27, design B1 and B2).
///
/// The findings: the join sentences were only in the TV's catalog — on the phone the bare code
/// appeared. And the refusals that PortalKit generates itself (no host, silent or unreadable
/// service, no single entry) carried a fixed German text that stood there in every language.
///
/// Counter-check: putting a key back into the TV catalog turns ``inSharedCatalog(code:)`` red;
/// the old fixed text in `PortalSource`/`PortalBridge` turns ``selfGenerated(scenario:)`` red.
@Suite("Rejection sentences in the shared catalog")
struct RejectionSetTests {

    /// What the server can refuse the app — join, login, invitation, token and the portal paths — and
    /// what PortalKit itself throws as a code.
    static let codes = [
        // Beitritt (`/join`, `/household/joins`)
        "join.bad_name", "join.bad_color", "join.no_want", "join.too_many", "join.too_often",
        "join.unknown", "join.admin_needs_pin", "join.pin_only_for_admin", "setup.required",
        "household.unknown_role", "household.person_exists",
        // Anmeldung, Einladung, Selbstanmeldung, Marke
        "auth.bad_credentials", "auth.locked_out", "auth.pin_format", "auth.required",
        "auth.profile_required", "auth.borrowed_profile", "auth.forbidden", "invite.used",
        "pairing.expired", "enroll.too_many_devices", "enroll.too_often", "enroll.unknown_mark",
        "mark.not_for_children",
        // Portalwege
        "stream.no_host", "stream.geo_blocked", "stream.drm", "stream.expired",
        "portal.broken", "state.unknown_key", "run.timeout", "run.crashed",
        "run.out_of_memory", "run.answer_too_large",
        // Von PortalKit selbst
        "portal.no_item", "portal.rejected",
    ]

    static func strings(_ location: CodeLocation) throws -> [String: Any] {
        let data = try Data(contentsOf: location.url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["strings"] as? [String: Any] ?? [:]
    }

    @Test("The sentence exists in wording, in de, en and tr — and in no app catalog", arguments: codes)
    func inSharedCatalog(code: String) throws {
        let key = try #require(
            PortalBridge.TestError.cancelled(status: 400, code: code, values: [:]).sentenceKey)
        let entry = try Self.strings(.wordingCatalog)[key] as? [String: Any]
        let languages = entry?["localizations"] as? [String: Any] ?? [:]
        for language in ["de", "en", "tr"] {
            let unit = (languages[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String ?? ""
            #expect(!value.isEmpty, "\(key) missing in \(language)")
        }
        for app in [CodeLocation.tvCatalog, .phoneCatalog] {
            #expect(try Self.strings(app)[key] == nil, "\(key) is in \(app)")
        }
    }

    /// The refusals that PortalKit generates itself — **verbatim as at their places**.
    static let selfGenerated: [PortalBridge.TestError] = [
        .unreachable(underlying: URLError(.cannotConnectToHost)),
        .unreadable,
        .noHost,
        PortalBridge.rejection(from: Data(), status: 503),
    ]

    @Test("A self-generated rejection has a key with a sentence", arguments: 0..<4)
    func selfGenerated(scenario: Int) throws {
        let error = Self.selfGenerated[scenario]
        let key = try #require(
            error.sentenceKey, "no key, what is shown: \(error.fallbackText)")
        #expect(try Self.strings(.wordingCatalog)[key] != nil, "\(key) is missing")
    }

    /// No German sentence any more as a refusal in PortalKit: whoever throws a new fixed text has to
    /// come past here.
    @Test("PortalKit throws no fixed text as a reason")
    func noFixedText() throws {
        for file in try SourceText.files(in: .portalKit) {
            let text = SourceText.strippingCommentLines(file.content)
            #expect(
                !text.contains("rejected(\n") && !text.contains("reason: \""),
                "\(file.relative) throws a fixed text")
        }
    }
}
