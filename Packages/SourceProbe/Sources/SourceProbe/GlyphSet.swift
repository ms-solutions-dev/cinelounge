import Foundation

/// Which SF Symbols exist **from which version** — for checks that hold symbol names.
///
/// **Why not simply resolve** (check finding B6 of 2026-09-27): `NSImage(systemSymbolName:)`
/// asks the machine's catalog, and that is macOS 27. A symbol that only came with SF Symbols 7
/// (tvOS/iOS 26) exists there and stays empty on the device with minimum version 18. The
/// version from which a name applies is in `name_availability.plist` of the system catalog:
/// `symbols` assigns each name a release year, `year_to_release` each year the
/// version per platform.
///
/// **A private path**, hence as a value that may be missing: ``systemSet`` is `nil` when
/// Apple moves the file. The checks demand it anyway (`#require`) — a
/// silent skip would be exactly the kind of green that checks nothing.
public struct GlyphSet: Sendable {

    /// The minimum version of both programs (`project.yml`, `Phone/project.yml`).
    public static let minimumVersion = "18.0"

    /// Where the catalog lies on the machine.
    public static let systemCatalogURL = URL(
        fileURLWithPath:
            "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/"
            + "CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    /// Name → Erscheinungsjahr, etwa `"server.rack"` → `"2020"`.
    public let years: [String: String]
    /// Erscheinungsjahr → Plattform → Fassung, etwa `"2024.1"` → `"tvOS"` → `"18.1"`.
    public let variants: [String: [String: String]]

    /// This machine's catalog — or `nil` when the file is missing.
    public static let systemSet: GlyphSet? = {
        guard let data = try? Data(contentsOf: systemCatalogURL),
            let board = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let years = board["symbols"] as? [String: String],
            let variants = board["year_to_release"] as? [String: [String: String]]
        else { return nil }
        return GlyphSet(years: years, variants: variants)
    }()

    public init(years: [String: String], variants: [String: [String: String]]) {
        self.years = years
        self.variants = variants
    }

    /// Why a name is missing on the device with the ``minimumVersion`` — `nil` when it is there.
    ///
    /// Both tvOS **and** iOS are checked: The shared registers draw on both devices.
    public func defect(_ name: String, since minimum: String = minimumVersion) -> String? {
        guard let year = years[name] else { return "\(name) is in no SF Symbols catalog" }
        guard let version = variants[year] else { return "\(name): year \(year) has no version table" }
        for platform in ["tvOS", "iOS"] {
            guard let since = version[platform] else { return "\(name): no \(platform) version" }
            if Self.compare(since, minimum) == .orderedDescending {
                return "\(name) exists only from \(platform) \(since) (SF Symbols \(year))"
            }
        }
        return nil
    }

    /// Fassungsnummern stellenweise verglichen — `"18.10"` liegt hinter `"18.4"`.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }
}
