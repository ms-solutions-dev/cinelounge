import Foundation

/// A location in the repo, **named instead of spelled out.**
///
/// **The only place where paths stand.** Until 2026-09-26 every
/// check computed its own way up from `#filePath`: fifteen root calculations of their own, around
/// forty-five read helpers, seven of them reaching from a package test into
/// `App/Sources`. Moving a package (decision 18) would have broken them all
/// one by one. Now at most one line breaks here, and ``QuelltextprobeTests``
/// reports it before a single check reads into the void.
///
/// **Folders and files in one board.** What a check reads is sometimes a whole
/// source folder, sometimes exactly one file that is not Swift (the language catalog, the
/// project file). Both are locations, and a restructuring moves both.
public enum CodeLocation: String, CaseIterable, Sendable {

    // MARK: Fernseher

    /// The TV's app target.
    case tvApp = "App/Sources"
    /// The TV's UI.
    case features = "Packages/Features/Sources/Features"
    case designSystem = "Packages/DesignSystem/Sources/DesignSystem"

    // MARK: Telefon

    /// The phone's app target.
    case phoneApp = "Phone/App/Sources"
    /// The phone's UI.
    case featuresPhone = "Phone/Packages/FeaturesPhone/Sources/FeaturesPhone"
    case designSystemPhone = "Phone/Packages/DesignSystemPhone/Sources/DesignSystemPhone"
    case networkState = "Phone/Packages/NetworkStatus/Sources/NetworkStatus"
    case downloads = "Phone/Packages/Downloads/Sources/Downloads"

    // MARK: Geteilt

    case core = "Packages/Core/Sources/Core"
    /// Shared since AP58 R0 — until 2026-09-26 under `Phone/Packages/`.
    case diagnose = "Packages/Diagnose/Sources/Diagnose"
    case jellyfinKit = "Packages/JellyfinKit/Sources/JellyfinKit"
    case parentalControls = "Packages/ParentalControls/Sources/ParentalControls"
    case playback = "Packages/Playback/Sources/Playback"
    case playlistKit = "Packages/PlaylistKit/Sources/PlaylistKit"
    case portalKit = "Packages/PortalKit/Sources/PortalKit"
    case profile = "Packages/ProfileKit/Sources/ProfileKit"
    case ratingsKit = "Packages/RatingsKit/Sources/RatingsKit"
    case secondScreen = "Packages/SecondScreen/Sources/SecondScreen"

    // MARK: Paketsammlungen

    /// All shared and TV packages — for checks that search **every** package.
    case packets = "Packages"
    /// The packages that only the phone has.
    case phonePackages = "Phone/Packages"
    /// The whole phone project, app, packages and scripts — for checks that search every
    /// Swift file of the phone, the checks themselves included.
    case phone = "Phone"

    // MARK: Dateien, die kein Swift sind

    /// The TV's language catalog.
    case tvCatalog = "App/Resources/Localizable.xcstrings"
    /// The phone's language catalog.
    case phoneCatalog = "Phone/App/Resources/Localizable.xcstrings"
    /// The shared language catalog (package `WordingKit`) — what both devices say.
    case wordingCatalog = "Packages/WordingKit/Sources/WordingKit/Resources/Localizable.xcstrings"
    /// The project description for xcodegen, TV.
    case tvProject = "project.yml"
    /// The project description for xcodegen, phone.
    case phoneProject = "Phone/project.yml"
    /// The TV's intros.
    case tvIntro = "App/Resources/Intro"
    /// The TV's asset catalog.
    case tvImages = "App/Resources/Assets.xcassets"
    /// The phone's asset catalog.
    case phoneImages = "Phone/App/Resources/Assets.xcassets"
    /// The manifest of `SecondScreen` — its check compares it with the sources.
    case secondScreenManifest = "Packages/SecondScreen/Package.swift"

    /// The location as an address.
    public var url: URL { SourceText.stem.appending(path: rawValue) }
}

/// A source file that was read.
public struct SourceFile: Sendable {
    /// The file name, for example `MainView.swift`.
    public let name: String
    /// The path from the location where the search happened, for example `Shell/MainView.swift`.
    public let relative: String
    /// The path from the repo root — for messages in which someone is supposed to find the file.
    public let path: String
    public let url: URL
    public let content: String
}

/// Reads source text for checks — **via ``CodeLocation`` and never via a path.**
public enum SourceText {

    /// The root of the repo.
    ///
    /// **Computed from this file and not from the check** that asks: This
    /// file lies in exactly one place, the checks in sixty.
    public static let stem: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SourceProbe
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // SourceProbe
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()

    /// What went wrong — with the name that was searched for.
    public enum TestError: Error, CustomStringConvertible {
        case notFound(String, CodeLocation)
        case ambiguous(String, CodeLocation, [String])

        public var description: String {
            switch self {
            case .notFound(let name, let location):
                "\(name) is not under \(location.rawValue) — moved? Then change the location here."
            case .ambiguous(let name, let location, let match):
                "\(name) appears several times under \(location.rawValue): \(match.joined(separator: ", "))"
            }
        }
    }

    /// A location that is itself a file — the language catalog, the project file.
    public static func read(_ location: CodeLocation) throws -> String {
        try String(contentsOf: location.url, encoding: .utf8)
    }

    /// A file **by its name** under a location, whatever the subfolder.
    ///
    /// **The name and not the path**, because files move within a package
    /// without anything about them changing. Whoever writes `Accounts/ProfileView.swift`
    /// breaks when the folder is called `Profile`; whoever writes `ProfileView.swift` does not.
    ///
    /// - Parameter name: The file name, or a path ending such as `Huelle/ShellModel.swift`,
    ///   when the name alone is not unique under the location.
    /// - Throws: ``TestError`` — when nothing or more than one file matches. **Never silently
    ///   the first**: A check that reads the wrong one of two files with the same name
    ///   stays green while the right one breaks.
    public static func file(_ name: String, in location: CodeLocation) throws -> URL {
        let match = allFiles(under: location.url).filter {
            $0.path.hasSuffix("/" + name)
        }
        guard let only = match.first else { throw TestError.notFound(name, location) }
        guard match.count == 1 else {
            throw TestError.ambiguous(name, location, match.map { relative($0, to: location.url) })
        }
        return only
    }

    /// The content of a file, found as in ``file(_:in:)``.
    public static func read(_ name: String, in location: CodeLocation) throws -> String {
        try String(contentsOf: file(name, in: location), encoding: .utf8)
    }

    /// All Swift files under a location, **including subfolders** and sorted by path.
    ///
    /// - Parameter unterordner: Only this folder under the location, for example `Settings`.
    public static func files(
        in location: CodeLocation, subfolder: String? = nil, fileExtension: String = "swift"
    ) throws -> [SourceFile] {
        let root = subfolder.map { location.url.appending(path: $0) } ?? location.url
        return try allFiles(under: root)
            .filter { $0.pathExtension == fileExtension }
            .map { url in
                SourceFile(
                    name: url.lastPathComponent,
                    relative: relative(url, to: location.url),
                    path: relative(url, to: stem),
                    url: url,
                    content: try String(contentsOf: url, encoding: .utf8))
            }
    }

    /// The text without lines that are only comments.
    ///
    /// **Because an explanation may name the old way.** A check "this call
    /// no longer occurs" would otherwise find it in the sentence that explains why it
    /// was dropped.
    public static func strippingCommentLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Innen

    /// All files under a folder, without build folders and without hidden ones.
    private static func allFiles(under root: URL) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var found: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.lastPathComponent == ".build" {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            found.append(url.standardizedFileURL)
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let full = url.standardizedFileURL.path
        let foreground = base.standardizedFileURL.path + "/"
        return full.hasPrefix(foreground) ? String(full.dropFirst(foreground.count)) : full
    }

    /// The entries an app can translate — **its own catalog and the shared one.**
    ///
    /// Since the final step of AP58, sentences that both devices say live in `WordingKit`
    /// and no longer in the app's catalog. A check that reads only the app catalog
    /// would report them as missing; the view finds them via `Text(app:)` in both.
    public static func catalogEntries(_ location: CodeLocation) throws -> [String: Any] {
        var entries: [String: Any] = [:]
        for catalog in [CodeLocation.wordingCatalog, location] {
            let data = try Data(contentsOf: catalog.url)
            let read = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for (key, value) in read?["strings"] as? [String: Any] ?? [:] {
                entries[key] = value
            }
        }
        return entries
    }
}
