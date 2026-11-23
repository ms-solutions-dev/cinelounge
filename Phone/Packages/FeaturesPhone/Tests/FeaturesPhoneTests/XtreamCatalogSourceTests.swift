import Testing

@testable import FeaturesPhone

/// Phone, 2026-09-29: Movies and series empty because a derived list ID
/// (`xtream|host|user`) was split at the first bar.
@Suite("Provider catalog: parsing the identifier")
struct XtreamCatalogSourceTests {

    @Test("Derived list identifier with pipes")
    func derived() throws {
        let movies = try #require(XtreamCatalogSource.parse("xtream|iptvhost.example|user1|vod"))
        #expect(movies.list == "xtream|iptvhost.example|user1")
        #expect(!movies.allSeries)
        let allSeries = try #require(XtreamCatalogSource.parse("xtream|iptvhost.example|user1|series"))
        #expect(allSeries.list == "xtream|iptvhost.example|user1")
        #expect(allSeries.allSeries)
    }

    @Test("UUID as list identifier")
    func uuid() throws {
        let movies = try #require(
            XtreamCatalogSource.parse("35657D19-4FE3-46C7-8A84-91FB84B7EAF9|vod"))
        #expect(movies.list == "35657D19-4FE3-46C7-8A84-91FB84B7EAF9")
    }

    @Test("Unknown kind or without a list")
    func nonsense() {
        #expect(XtreamCatalogSource.parse("liste|live") == nil)
        #expect(XtreamCatalogSource.parse("|vod") == nil)
        #expect(XtreamCatalogSource.parse("vod") == nil)
    }
}
