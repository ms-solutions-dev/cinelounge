import Foundation

/// A storage location for small strings.
///
/// Written as a protocol so that tests do not have to touch the real Keychain.
/// On a Mac that one blocks as soon as it expects a
/// confirmation — a test run then simply stops, without
/// an error message. That is exactly what happened when this store was built.
public protocol KeyValueStore: Sendable {
    func set(_ value: String, for key: String) throws
    func value(for key: String) throws -> String
    func remove(_ key: String) throws
}

extension SecureStore: KeyValueStore {}

/// Volatile store in working memory — exclusively for tests.
public final class InMemoryStore: KeyValueStore, @unchecked Sendable {

    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func value(for key: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[key] else { throw SecureStore.Failure.notFound }
        return value
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
