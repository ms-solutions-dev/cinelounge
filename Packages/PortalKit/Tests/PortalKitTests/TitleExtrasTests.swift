import Foundation
import Testing

@testable import PortalKit

/// Title extras and the providers behind them.
@Suite("Portals: title extras")
struct TitleExtrasTests {

    @Test("An ISO date becomes day.month.year")
    func readableDate() {
        #expect(TitleExtras(label: "X", date: "2026-10-11").readableDate == "11.10.2026")
    }

    @Test("A date in another form stays as it came")
    func foreignDate() {
        #expect(TitleExtras(label: "X", date: "2026").readableDate == "2026")
        #expect(TitleExtras(label: "X").readableDate == "")
    }

    /// A provider that answers for one portal only and remembers what it was asked.
    final class Probe: TitleExtrasProvider, @unchecked Sendable {
        let portal: String
        let answer: TitleExtras
        private(set) var asked: [String] = []

        init(portal: String, answer: TitleExtras) {
            self.portal = portal
            self.answer = answer
        }

        func extras(
            portal: String, itemID: String, title: String, source: PortalSource
        ) async
            -> TitleExtras?
        {
            asked.append(itemID)
            return portal == self.portal ? answer : nil
        }
    }

    static let source = PortalSource(bridge: PortalBridge(basis: URL(string: "http://127.0.0.1:9")!))

    @Test("Without a provider nothing is asked and nothing comes back")
    func withoutProvider() async {
        let found = await Self.source.extras(
            forItem: "beispiel|x|/film/1", title: "Ein Titel", from: AppExtensions())
        #expect(found == nil)
    }

    @Test("The first provider with an answer wins, in registration order")
    func order() async {
        let extensions = AppExtensions()
        let other = Probe(portal: "anderes", answer: TitleExtras(label: "A"))
        let match = Probe(portal: "beispiel", answer: TitleExtras(label: "B"))
        let late = Probe(portal: "beispiel", answer: TitleExtras(label: "C"))
        for p in [other, match, late] { extensions.add(extrasProvider: p) }

        let found = await Self.source.extras(
            forItem: "beispiel|x|/film/1", title: "Ein Titel", from: extensions)

        #expect(found?.label == "B")
        #expect(other.asked == ["beispiel|x|/film/1"])
        #expect(late.asked.isEmpty)
    }

    @Test("No title or no portal identifier — no provider is asked")
    func noQuestion() async {
        let extensions = AppExtensions()
        let probe = Probe(portal: "beispiel", answer: TitleExtras(label: "B"))
        extensions.add(extrasProvider: probe)

        #expect(await Self.source.extras(forItem: "beispiel|x|/film/1", title: "", from: extensions) == nil)
        #expect(await Self.source.extras(forItem: "", title: "Titel", from: extensions) == nil)
        #expect(probe.asked.isEmpty)
    }
}

/// A test extension with a stable Objective-C name, found the way the app finds its own.
@objc(CLTestExtension)
final class TestExtension: NSObject, AppExtension {
    static func install(into extensions: AppExtensions) {
        extensions.add(
            extrasProvider: TitleExtrasTests.Probe(portal: "beispiel", answer: TitleExtras(label: "T")))
    }
}

@Suite("Extensions are loaded by name")
struct AppExtensionsTests {

    @Test("A listed class is installed once, an unknown name is reported")
    func byName() {
        let extensions = AppExtensions()
        let unresolved = AppExtensions.install(
            ["CLTestExtension", "CLMissingExtension", "CLTestExtension"], into: extensions)

        #expect(unresolved == ["CLMissingExtension"])
        #expect(extensions.extrasProviders.count == 1)
        #expect(extensions.installed == ["CLTestExtension"])
    }

    @Test("A class that is no extension is skipped")
    func notAnExtension() {
        let extensions = AppExtensions()
        #expect(AppExtensions.install(["NSObject"], into: extensions) == ["NSObject"])
        #expect(extensions.extrasProviders.isEmpty)
    }

    @Test("Without the Info.plist key nothing is loaded")
    func withoutKey() {
        let extensions = AppExtensions()
        #expect(AppExtensions.load(from: Bundle(for: TestExtension.self), into: extensions).isEmpty)
        #expect(extensions.extrasProviders.isEmpty)
    }
}
