import Core
import Foundation
import Synchronization
import WordingKit

/// An extension the app loads at start — **by class name from the Info.plist, never by import.**
///
/// The app itself knows no extension. A build that wants one lists the class under
/// `CLExtensionClasses` (an array of strings) in its Info.plist and links the package that
/// carries it. ``AppExtensions/load(from:into:)`` finds the class with `NSClassFromString` and
/// calls ``install(into:)``. The class therefore needs a stable Objective-C name:
///
/// ```swift
/// @objc(MyExtension) final class MyExtension: NSObject, AppExtension {
///     static func install(into extensions: AppExtensions) { … }
/// }
/// ```
public protocol AppExtension: AnyObject {

    /// Registers what the extension contributes — providers, catalogs.
    static func install(into extensions: AppExtensions)
}

/// The app's extension points — **empty by default, and the app works the same without them.**
///
/// What can be contributed:
/// - ``extrasProviders``: details on portal titles (``TitleExtrasProvider``).
/// - ``wordingBundles``: catalogs with sentences for error codes or states the core does not
///   know. They are asked after the shared catalog `WordingKit`; a key the core carries itself is
///   never overridden.
///
/// Registration happens once at program start, before the first view is built — see
/// ``load(from:into:)``.
public final class AppExtensions: Sendable {

    /// The instance the app uses. Checks build their own.
    public static let shared = AppExtensions()

    private let providers = Mutex<[any TitleExtrasProvider]>([])
    private let loaded = Mutex<[String]>([])

    public init() {}

    /// The registered providers of title details, in registration order.
    public var extrasProviders: [any TitleExtrasProvider] { providers.withLock { $0 } }

    /// Adds a provider of title details.
    public func add(extrasProvider provider: any TitleExtrasProvider) {
        providers.withLock { $0.append(provider) }
    }

    /// The registered catalogs — they live in `WordingKit`, because every lookup passes there.
    public var wordingBundles: [Bundle] { WordingKit.extensionBundles }

    /// Adds a catalog with additional sentences.
    public func add(wordingBundle bundle: Bundle) {
        WordingKit.register(bundle)
    }

    /// The class names that were installed — for the diagnostic log.
    public var installed: [String] { loaded.withLock { $0 } }

    /// Installs every extension the Info.plist names under `CLExtensionClasses`.
    ///
    /// A name that does not resolve to an ``AppExtension`` class is skipped and logged: a build
    /// without the package must still start, and the log line is where one sees that a listed
    /// class was not linked. The same name is never installed twice.
    ///
    /// - Returns: The names that could not be resolved.
    @discardableResult
    public static func load(
        from bundle: Bundle = .main, into extensions: AppExtensions = .shared
    )
        -> [String]
    {
        let names = bundle.object(forInfoDictionaryKey: "CLExtensionClasses") as? [String] ?? []
        let unresolved = install(names, into: extensions)
        if !unresolved.isEmpty {
            Diagnostics.flow.error(
                "Extensions not found: \(unresolved.joined(separator: ", "), privacy: .public)")
        }
        return unresolved
    }

    /// Installs the named classes — the part of ``load(from:into:)`` that does not need a bundle.
    @discardableResult
    public static func install(_ names: [String], into extensions: AppExtensions) -> [String] {
        var unresolved: [String] = []
        for name in names {
            guard let type = NSClassFromString(name) as? any AppExtension.Type else {
                unresolved.append(name)
                continue
            }
            let isNew = extensions.loaded.withLock { list in
                guard !list.contains(name) else { return false }
                list.append(name)
                return true
            }
            if isNew { type.install(into: extensions) }
        }
        return unresolved
    }
}
