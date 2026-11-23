import Foundation

/// A value that arrives **once**, and a wait for it.
///
/// **Why, when `withCheckedContinuation` exists.** Because `Network.framework` gives its
/// information through callbacks that fire **multiple times**: `stateUpdateHandler` reports
/// `.preparing`, then `.ready`, then maybe `.failed`. Resuming a continuation twice
/// is a crash in Swift — and one that comes exactly when
/// the network behaves unusually, i.e. in the rarest and hardest-to-reproduce
/// case.
///
/// **The lock and not an actor.** The callback arrives on a foreign queue
/// and must not wait; an `await` at this point would block the queue of
/// `Network.framework`.
///
/// **Whoever asks for the value when it is already there gets it immediately.** Without that there would be
/// a race: The connection can report `.ready` before the caller starts to wait.
final class OneShot<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var isSet: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    /// Setzt den Wert — **jeder weitere Ruf tut nichts.**
    func give(_ value: Value) {
        lock.lock()
        guard isSet == nil else {
            lock.unlock()
            return
        }
        isSet = value
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: value) }
    }

    /// Waits until it is there.
    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            lock.lock()
            if let isSet {
                lock.unlock()
                continuation.resume(returning: isSet)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
