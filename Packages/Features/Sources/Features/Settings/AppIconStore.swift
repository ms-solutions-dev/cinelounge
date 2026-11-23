import Core
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A selectable app icon.
///
/// ``alternateName`` is the name of the image stack in the asset catalog. `nil` stands for
/// the default icon — it deliberately has **no** stack of its own: the system knows it
/// as "no alternate icon", and `setAlternateIconName(nil)` leads back to it.
public struct AppIcon: Identifiable, Equatable, Sendable {

    public let alternateName: String?
    public let titleKey: String
    /// A flat image for the tile in the settings. From an image stack no image can be drawn
    /// inside the app — it exists only as the Home Screen icon, not as a resource.
    public let preview: String

    public var id: String { alternateName ?? "original" }
}

/// What the store needs from the system.
///
/// A protocol of its own, so that the selection logic is testable without a running app:
/// `UIApplication.shared` does not exist in a test run, and the system dialog (see below)
/// certainly cannot be pressed there.
public protocol AppIconSwitching: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var currentIconName: String? { get }
    func setIcon(_ name: String?) async throws
}

#if canImport(UIKit)
    /// The path via UIKit.
    public final class SystemAppIcons: AppIconSwitching {

        public init() {}

        public var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
        public var currentIconName: String? { UIApplication.shared.alternateIconName }

        public func setIcon(_ name: String?) async throws {
            // The type is written out: without a return value Swift cannot infer it from the body
            // ("generic parameter 'T' could not be inferred").
            try await withCheckedThrowingContinuation {
                (resume: CheckedContinuation<Void, any Error>) in
                UIApplication.shared.setAlternateIconName(name) { error in
                    if let error {
                        resume.resume(throwing: error)
                    } else {
                        resume.resume()
                    }
                }
            }
        }
    }
#else
    /// macOS has no alternate icons. The class exists anyway, because the test suite builds
    /// for macOS too — without it every call site in the UI would need its own condition around
    /// the compilation.
    public final class SystemAppIcons: AppIconSwitching {

        public init() {}

        public var supportsAlternateIcons: Bool { false }
        public var currentIconName: String? { nil }

        public func setIcon(_ name: String?) async throws {}
    }
#endif

/// Holds the chosen app icon.
///
/// **The state is not remembered itself.** `alternateIconName` asks the system what
/// currently applies — an entry of our own in the store slot would be a second truth that
/// can drift apart (the viewer cannot change the icon elsewhere, but a failed switch would
/// otherwise leave an entry with no counterpart on the Home Screen).
///
/// **The system dialog decides, not we.** On every change tvOS shows
/// "You have changed the icon for …" with an OK button. That is not a display afterwards
/// but a confirmation prompt: while it is up, the callback does not return, and whoever
/// dismisses it gets an error and **no** change. Measured on the simulator on 2026-08-29 —
/// on the first startup without confirmation the default icon was back after a restart.
/// That is why, after a failure, the system is asked instead of guessing.
public final class AppIconStore: ObservableObject {

    /// The selection. The default icon comes first — it is the state everyone returns to, and
    /// the only one nobody chose.
    public static let all: [AppIcon] = [
        AppIcon(alternateName: nil, titleKey: "settings.icon.original", preview: "VorschauOriginal"),
        AppIcon(
            alternateName: "SymbolSessel", titleKey: "settings.icon.sessel",
            preview: "VorschauSessel"),
        AppIcon(
            alternateName: "SymbolBogen", titleKey: "settings.icon.bogen",
            preview: "VorschauBogen"),
        AppIcon(
            alternateName: "SymbolNegativ", titleKey: "settings.icon.negativ",
            preview: "VorschauNegativ"),
        AppIcon(
            alternateName: "SymbolNegativSchrift", titleKey: "settings.icon.negativSchrift",
            preview: "VorschauNegativSchrift"),
    ]

    @Published public private(set) var current: AppIcon
    /// Is a switch currently awaiting confirmation from the viewer? While that holds, the
    /// button stays quiet instead of triggering a second dialog.
    @Published public private(set) var isSwitching = false

    public let isSupported: Bool

    private let system: any AppIconSwitching

    public init(system: any AppIconSwitching) {
        self.system = system
        isSupported = system.supportsAlternateIcons
        current = Self.icon(named: system.currentIconName) ?? Self.all[0]
    }

    public func choose(_ icon: AppIcon) async {
        guard icon != current, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await system.setIcon(icon.alternateName)
            current = icon
        } catch {
            Diagnostics.defect(
                "App icon not changed: \(Diagnostics.explain(error))", since: nil,
                area: "Oberfläche")
            // Rejected or failed: the system knows what applies.
            current = Self.icon(named: system.currentIconName) ?? Self.all[0]
        }
    }

    static func icon(named name: String?) -> AppIcon? {
        all.first { $0.alternateName == name }
    }
}
