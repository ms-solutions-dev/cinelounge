import Foundation
import Testing

@testable import Core

/// **The probe asks no more than necessary** (AP69, 2026-10-11): the start from the
/// downloads instead of a connection, and one finding per address stays remembered.
/// The network itself is not checked here — an address without a remote end yields
/// `nil`, nothing more.
@Suite("Container probe without a third connection", .serialized)
struct ContainerProbeDownloadsTests {

    private let address = URL(string: "http://127.0.0.1:9/series/u/p/361595.mp4")!

    private var mp4Start: Data {
        var bytes = Data([0x00, 0x00, 0x00, 0x20])
        bytes.append(contentsOf: Array("ftypisom".utf8))
        bytes.append(Data(repeating: 0, count: 100))
        return bytes
    }

    @Test("If the start is available, no request goes out")
    func fromDownloads() async {
        ContainerProbe.forget()
        // The address has no remote end — if a request came, the result would be `nil`.
        #expect(await ContainerProbe.read(address, start: mp4Start) == .mp4)
    }

    @Test("A finding is remembered per address")
    func remembered() async {
        ContainerProbe.forget()
        #expect(ContainerProbe.remembered(forItem: address) == nil)
        _ = await ContainerProbe.read(address, start: mp4Start)
        #expect(ContainerProbe.remembered(forItem: address) == .mp4)
        // Without start and without remote end: the remembered finding carries.
        #expect(await ContainerProbe.read(address) == .mp4)
    }

    @Test("Without downloads and without a remote end: no finding, no error")
    func withoutAnything() async {
        ContainerProbe.forget()
        #expect(await ContainerProbe.read(address, headers: ["User-Agent": "x"]) == nil)
    }
}
