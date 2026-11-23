import Core
import Foundation
import PortalKit

/// Whether the standing portal source asks with an **outdated profile header** — and
/// therefore has to be rebuilt (track G, 2026-09-25).
///
/// **The finding:** ``ProfileKit/ProfileSwitch`` writes the header (`setup.deviceProfile`) on
/// every switch from the portal person of the new profile — also on a remote relocation
/// (``ProfileKit/ProfileSwitch/followUpMove(from:ledgerStore:keychain:deviceStore:)``).
/// The bridge, however, reads it only **at build time**. If the media-server session
/// stayed the same (``ProfileModel/SessionSequence/remains``), nobody rebuilt it, and the
/// portals kept answering for the person before.
///
/// **The comparison is against what the source actually sends**, and not against a
/// "before" that the shell would have to remember. A remembered value would have to be
/// kept up to date at every place where the source is recreated (``MainView`` builds it
/// at four); ``PortalKit/PortalSource/profileHeader`` is always the current one.
enum PortalHeaderGuard {

    /// - Parameters:
    ///   - quelle: the header of the standing source — `.none` if there is no source.
    ///   - jetzt: ``Core/DeviceTrait/profile(from:)`` after the switch.
    /// - Returns: `true` if a rebuild is needed. **Never without a source:** where no
    ///   bridge is set up there is nothing to rebuild, and a build would only call it.
    nonisolated static func shouldRebuild(source: String??, now: String?) -> Bool {
        guard let built = source else { return false }
        return built != now
    }

    /// Dieselbe Frage an einer Quelle.
    nonisolated static func shouldRebuild(_ source: PortalSource?, now: String?) -> Bool {
        guard let source else { return false }
        let header: String?? = .some(source.profileHeader)
        return shouldRebuild(source: header, now: now)
    }

    /// Whether the standing source is **no longer the one of the active profile** — header,
    /// trait, or whether there is one at all.
    ///
    /// **The finding (test Apple TV, 2026-09-28):** After the switch every profile showed
    /// the CL-Server of the person before, and the device made no further request at all.
    /// The guard compared only the header; on a device with a person it is always empty.
    /// Since the trait is kept per profile, it changes with the profile — and a profile
    /// without a CL-Server has no source at all, while one with a CL-Server has one, even
    /// if the previous one had none.
    nonisolated static func isStale(_ source: PortalSource?, expectedValue: PortalSource?) -> Bool {
        switch (source, expectedValue) {
        case (nil, nil): false
        case (nil, _), (_, nil): true
        case (let settled?, let fresh?):
            settled.profileHeader != fresh.profileHeader || settled.trait != fresh.trait
        }
    }
}
