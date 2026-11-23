/// Where a download entry comes from — **three kinds and not five.**
///
/// `Catalog.Origin` in the view package has five cases; here there are three, and the
/// two missing ones are missing for a reason:
///
/// * **A channel list does not occur.** A channel has no beginning and no end;
///   what one would download from it is a recording and not a copy. That is a
///   different process with different questions (when, how long, what happens on a
///   schedule change) and does not belong in this package.
/// * **The downloads themselves do not occur.** They are the subset of the others that is
///   already here; listing itself as a source would produce a download job that
///   fetches a file it already has.
///
/// **And this package does not know `Catalog.Origin`.** The type lives in `FeaturesPhone`,
/// and that package depends on this one — the direction only goes one way. The mapping
/// between the two therefore lives where both are known, and not here.
public enum SourceKind: String, Sendable, Hashable, Codable, CaseIterable {

    /// Jellyfin. The server transcodes, so there are tiers.
    case jellyfin = "medienserver"

    /// A provider's catalog (Xtream VOD). Exactly one stream per title.
    case provider = "anbieter"

    /// A portal. Host and language version instead of resolution.
    case portal
}
