import Testing

@testable import NetworkStatus

@Suite("Bandwidth memory")
struct BandwidthMemoryTests {

    private let wifi = NetworkPath(kind: .wifi)
    private let mobile = NetworkPath(kind: .cellular, expensive: true)

    @Test("What was measured is there")
    func remember() {
        var memory = BandwidthMemory()
        memory.memorize(28.4, route: wifi, changeCount: 3)
        #expect(memory.value(route: wifi, changeCount: 3) == 28.4)
    }

    /// The core: **bound to the network path, not to the clock.** A measurement on home Wi-Fi
    /// says nothing about the Wi-Fi in the café — and both are called "Wi-Fi". The counter from
    /// the network watch separates them.
    @Test("After a change the measurement no longer applies")
    func switchInvalidates() {
        var memory = BandwidthMemory()
        memory.memorize(28.4, route: wifi, changeCount: 3)
        #expect(memory.value(route: wifi, changeCount: 4) == nil)
    }

    @Test("A value from cellular does not apply on Wi-Fi")
    func pathsSeparate() {
        var memory = BandwidthMemory()
        memory.memorize(1.2, route: mobile, changeCount: 7)
        #expect(memory.value(route: wifi, changeCount: 7) == nil)
        #expect(memory.value(route: mobile, changeCount: 7) == 1.2)
    }

    /// Without a measurement **nothing is guessed**. The design promises "not yet measured" in
    /// several places — an invented number would be worse than none.
    @Test("Without a measurement there is no answer")
    func inventNothing() {
        let memory = BandwidthMemory()
        #expect(memory.carries(2.8, route: wifi, changeCount: 1) == nil)
    }

    @Test("With a measurement it compares")
    func comparison() {
        var memory = BandwidthMemory()
        memory.memorize(0.31, route: wifi, changeCount: 1)
        #expect(memory.carries(2.8, route: wifi, changeCount: 1) == false)
        #expect(memory.carries(0.2, route: wifi, changeCount: 1) == true)
    }

    @Test("Remember nothing for nothing")
    func zeroIsNotRemembered() {
        var memory = BandwidthMemory()
        memory.memorize(0, route: wifi, changeCount: 1)
        #expect(memory.value(route: wifi, changeCount: 1) == nil)
    }
}
