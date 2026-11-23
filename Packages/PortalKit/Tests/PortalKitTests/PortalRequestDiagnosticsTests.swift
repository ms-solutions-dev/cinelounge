import Core
import Foundation
import Testing

@testable import PortalKit

/// **Diagnostics coverage of ``PortalBridge/send(_:)``** (2026-09-27): Every request that
/// does not arrive, is rejected with `>= 400` or cannot be read now writes a line via
/// ``Core/Diagnostics/defect(_:since:area:)``.
///
/// **What is checked here is the classification, not the delivery.** What goes into the
/// line is `Diagnostics.explain(error)` over exactly the ``PortalBridge/TestError`` that
/// this check already sees through the return value of `fetch(_:_:)` — the same value, no
/// second path. Whether `Diagnostics.defect` itself reliably writes to the trace is a
/// matter for `Grundstock`/`Core` and not this package.
@Suite("Portal requests fail recognizably — status and code, no address")
struct PortalRequestDiagnosticsTests {

    private struct Nothing: Decodable {}

    @Test("A rejection with a server code carries status and code — the line that goes into the log")
    func rejectedWithCode() async throws {
        let data = Data(#"{"error":{"code":"stream.no_host","values":{"land":"DE"}}}"#.utf8)
        let line = Stub.setUp(status: 404, data: data)
        let bridge = PortalBridge(
            basis: line.basis, dialect: .cinelounge, session: Stub.session)

        do {
            let _: Nothing = try await bridge.fetch("quellen")
            Issue.record("should have thrown")
        } catch let error as PortalBridge.TestError {
            guard case .cancelled(let status, let code, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(status == 404)
            #expect(code == "stream.no_host")

            // The same translation that ``PortalBridge/send(_:)`` hands to
            // `Diagnostics.defect` — status and code are in it, no address.
            let row = Diagnostics.explain(error)
            #expect(row.contains("404"))
            #expect(row.contains("stream.no_host"))
            #expect(!row.contains("://"))
        }
    }

    @Test("A rejection without a server code falls back to status and raw text")
    func rejectedWithoutCode() async throws {
        let line = Stub.setUp(status: 503, data: Data())
        let bridge = PortalBridge(
            basis: line.basis, dialect: .cinelounge, session: Stub.session)

        do {
            let _: Nothing = try await bridge.fetch("quellen")
            Issue.record("should have thrown")
        } catch let error as PortalBridge.TestError {
            guard case .cancelled(let status, let code, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(status == 503)
            #expect(code == "portal.rejected")
        }
    }

    @Test("An unreadable response is recognized as such")
    func unreadable() async throws {
        let line = Stub.setUp(status: 200, data: Data("kein json".utf8))
        let bridge = PortalBridge(
            basis: line.basis, dialect: .cinelounge, session: Stub.session)

        do {
            let _: Nothing = try await bridge.fetch("quellen")
            Issue.record("should have thrown")
        } catch let error as PortalBridge.TestError {
            guard case .unreadable = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }
}
