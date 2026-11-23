import Core
import Foundation
import Testing

@testable import ProfileKit

/// **Two identical profiles in the switcher** — AP48, 2026-09-24.
///
/// The finding came while working through AP48 and is not a missing feature but a
/// duplicated human: ``ProfileCloud/adopt(_:)`` checks by **ID**, and every
/// device assigns that fresh on first start. The same person is called something different on the TV than on the
/// phone — not in the name but in the ID —, and iCloud therefore puts them into the book
/// a second time.
@Suite("Merging device and cloud")
struct ProfileSyncTests {

    private static let server = URL(string: "https://jellyfin.example")!

    private static func account(_ user: String) -> Access {
        .jellyfin(server: server, userID: user, username: user)
    }

    /// **The case this is about.** A TV that on first start created "Alex",
    /// and an iPhone that did the same. Result: **one** profile.
    static let lowercased = Profile.Identifier(rawValue: "00000000-0000-4000-8000-000000000001")
    static let large = Profile.Identifier(rawValue: "FFFFFFFF-0000-4000-8000-000000000002")

    @Test("Same name, different identifier — one person")
    func sameNameBecomesOne() {
        let here = Profile(identifier: Self.large, name: "Max", credentials: [Self.account("max")])
        let there = Profile(identifier: Self.lowercased, name: "Max", color: .moss)

        let result = ProfileSync.merge(device: [here], cloud: [there])

        #expect(result.profile.count == 1)
        #expect(result.toAsk.isEmpty)
        // The smaller ID applies — here the cloud's.
        #expect(result.profile.first?.identifier == there.identifier)
        // This household's access stays — otherwise the TV shows nothing afterwards.
        #expect(result.profile.first?.jellyfin == Self.account("max"))
    }

    /// "alex" on the TV, "Alex " on the phone: **the same input from two keyboards**,
    /// and only one of them capitalizes by itself.
    @Test("Capitalization and edges do not count")
    func spellingDoesNotCount() {
        let here = Profile(name: "max")
        let there = Profile(name: "Max ")
        #expect(ProfileSync.merge(device: [here], cloud: [there]).profile.count == 1)
    }

    /// **The safety-relevant case.** If one side says "child" and the other
    /// "adult", child applies — otherwise whether parental controls lapse would depend on
    /// which device synced last, and a protection that depends on an order
    /// is none.
    @Test("When the kind disagrees the stricter one wins")
    func childWins() {
        let childHere = Profile(name: "Selin", kind: .kind)
        let adultThere = Profile(name: "Selin", kind: .adult)
        #expect(
            ProfileSync.merge(device: [childHere], cloud: [adultThere])
                .profile.first?.kind == .kind)

        // And the same in the other direction.
        let adultHere = Profile(name: "Selin", kind: .adult)
        let childThere = Profile(name: "Selin", kind: .kind)
        #expect(
            ProfileSync.merge(device: [adultHere], cloud: [childThere])
                .profile.first?.kind == .kind)
    }

    /// **Different names, same access: asked and not decided.** "Alex"
    /// here, "Parent" there — that can be the same person or a shared Jellyfin
    /// access, and in a household both occur.
    @Test("The same media server under different names triggers a question")
    func suspicionIsAsked() {
        let here = Profile(name: "Max", credentials: [Self.account("max")])
        let there = Profile(name: "Papa", credentials: [Self.account("max")])

        let result = ProfileSync.merge(device: [here], cloud: [there])

        // Both stay.
        #expect(result.profile.count == 2)
        #expect(result.toAsk.count == 1)
        #expect(result.toAsk.first?.device == here.identifier)
        #expect(result.toAsk.first?.cloud == there.identifier)
    }

    /// A profile that was created on the iPhone and has never seen this TV.
    @Test("What is only in the cloud is added")
    func newFromCloud() {
        let here = Profile(name: "Max")
        let there = Profile(name: "Selin", kind: .kind)

        let result = ProfileSync.merge(device: [here], cloud: [there])

        #expect(result.profile.count == 2)
        #expect(result.toAsk.isEmpty)
        #expect(result.profile.contains { $0.name == "Selin" })
    }

    /// **Two people with the same name stay two** — but only once.
    ///
    /// If the cloud holds two "Alex" (because two devices created him twice),
    /// the own one must not merge with both. The second stays on its own
    /// and is then the case that a human has to look at.
    @Test("A device profile merges with at most one from the cloud")
    func mergeOnlyOnce() {
        let here = Profile(name: "Max")
        let there1 = Profile(name: "Max")
        let there2 = Profile(name: "Max")

        let result = ProfileSync.merge(device: [here], cloud: [there1, there2])

        #expect(result.profile.count == 2)
    }

    /// **The iPhone of 2026-09-28:** two "Alex" on the device, only the second is up there. The
    /// first must not claim the cloud entry via the name (otherwise a tombstone
    /// for an ID that lives on), but merges into the second with its IPTV list.
    @Test("A second device profile of the same name is absorbed by the cloud profile")
    func twinMergesIn() {
        let list = Access.channelList(identifier: "liste-1")
        let hereOnly = Profile(identifier: Self.lowercased, name: "Max", credentials: [list])
        let top = Profile(identifier: Self.large, name: "Max", credentials: [Self.account("max")])

        let result = ProfileSync.merge(
            device: [hereOnly, top], cloud: [top])

        #expect(result.profile.map(\.identifier) == [Self.large])
        #expect(result.absorbed.isEmpty)
        #expect(result.migrated == [Self.lowercased: Self.large])
        #expect(result.profile.first?.channelLists == [list])
        #expect(result.profile.first?.jellyfin == Self.account("max"))
        #expect(result.now(Self.lowercased) == Self.large)
    }

    /// An empty name must not connect everything with everything.
    @Test("Empty names merge nothing")
    func emptyLinksNothing() {
        #expect(!ProfileSync.sameName("", ""))
        #expect(!ProfileSync.sameName("   ", "Max"))
    }

    /// **Whoever is watching stays the same** — the case noticed while wiring up.
    ///
    /// ``ProfileBook/init(profile:active:)`` falls back to `profile.first` if the
    /// active ID no longer occurs. When merging it no longer occurs exactly when it
    /// was **replaced** by the cloud's — and then the viewer landed on the first-named
    /// human in the book, in the middle of a film.
    @Test("The active identifier moves along")
    func activeMigratesAlong() {
        let here = Profile(identifier: Self.large, name: "Max")
        let there = Profile(identifier: Self.lowercased, name: "Max")

        let result = ProfileSync.merge(device: [here], cloud: [there])

        #expect(result.migrated[here.identifier] == there.identifier)
        #expect(result.now(here.identifier) == there.identifier)
    }

    /// **If this device's ID wins, the cloud's merges into it** (cross-check
    /// strand C, R1b) — the label still comes from up there, only the ID stays.
    @Test("The smaller identifier wins, even if it is the device's")
    func deviceWins() {
        let here = Profile(identifier: Self.lowercased, name: "Max", credentials: [Self.account("max")])
        let there = Profile(identifier: Self.large, name: "Max", color: .moss)

        let result = ProfileSync.merge(device: [here], cloud: [there])

        #expect(result.profile.map(\.identifier) == [here.identifier])
        #expect(result.profile.first?.color == .moss, "the labeling comes from above")
        #expect(result.profile.first?.jellyfin == Self.account("max"))
        #expect(result.migrated.isEmpty)
        #expect(result.absorbed == [there.identifier: here.identifier])
        #expect(result.now(here.identifier) == here.identifier)
        // And the other device, which sees the same pair the other way round, makes the same choice.
        let otherSide = ProfileSync.merge(device: [there], cloud: [here])
        #expect(otherSide.profile.map(\.identifier) == [here.identifier])
        #expect(otherSide.migrated == [there.identifier: here.identifier])
    }

    @Test("The winner does not depend on spelling")
    func winnerSpelling() {
        let lowercased = Profile.Identifier(rawValue: Self.lowercased.rawValue.lowercased())
        #expect(ProfileSync.wins(lowercased, about: Self.large))
        #expect(!ProfileSync.wins(Self.large, about: lowercased))
        #expect(!ProfileSync.wins(Self.lowercased, about: Self.lowercased))
    }

    /// Whoever does not migrate stays — otherwise the mapping would be a second place for the same
    /// ID and would have to be carried along everywhere.
    @Test("What does not move keeps its identifier")
    func idStaysWithoutMigration() {
        let here = Profile(name: "Max")
        let there = Profile(name: "Selin")

        let result = ProfileSync.merge(device: [here], cloud: [there])

        #expect(result.migrated.isEmpty)
        #expect(result.now(here.identifier) == here.identifier)
        #expect(result.now(nil) == nil)
    }

    /// **A book in which the active profile merges shows the same person afterwards.**
    ///
    /// The check above holds the computation; this one holds the result that ``ProfileBook``
    /// makes of it — and only here does the fallback in question take effect.
    @Test("The book after merging still shows the same person")
    func bookKeepsThePerson() {
        let childProfile = Profile(name: "Selin", kind: .kind)
        let max = Profile(name: "Max")
        // The child profile comes first: Without migrating along, "active" would fall back to it.
        let previous = ProfileBook(profile: [childProfile, max], active: max.identifier)

        let result = ProfileSync.merge(
            device: previous.profile, cloud: [Profile(name: "Max")])
        let after = ProfileBook(profile: result.profile, active: result.now(previous.active))

        #expect(after.activeProfile?.name == "Max")
    }

    // MARK: - The open question survives the sync

    /// **The finding in our own build of the same day:** The computation delivered `toAsk`,
    /// and ``ProfileCloud/adopt(_:)`` used none of it. The merge ran
    /// correctly, the open question disappeared — AP48's promise "unclear stays two profiles,
    /// the switcher shows 'merge?'" was thus half fulfilled: Two remained,
    /// but nobody could ever find out why.
    @Test("An open question is stored and found again")
    func questionSurvives() {
        let bucket = InMemoryStore()
        let pair = ProfileSync.Pair(device: .fresh(), cloud: .fresh())

        ProfileSync.memorize([pair], in: bucket)

        #expect(ProfileSync.openQuestions(from: bucket) == [pair])
    }

    /// **An empty list deletes the entry** — whoever has answered a question should
    /// not see it again at the next sync.
    @Test("No questions means no entry")
    func emptyListDeletes() {
        let bucket = InMemoryStore()
        ProfileSync.memorize([ProfileSync.Pair(device: .fresh(), cloud: .fresh())], in: bucket)
        ProfileSync.memorize([], in: bucket)
        #expect(ProfileSync.openQuestions(from: bucket).isEmpty)
    }

    /// **Both answers strike the question** — "merge" and "keep two".
    ///
    /// The second is not a non-answer: Whoever gives it has decided, and asking the question once
    /// more would be not believing their decision.
    @Test("An answered question disappears, the other stays")
    func answeredDisappears() {
        let bucket = InMemoryStore()
        let single = ProfileSync.Pair(device: .fresh(), cloud: .fresh())
        let other = ProfileSync.Pair(device: .fresh(), cloud: .fresh())
        ProfileSync.memorize([single, other], in: bucket)

        ProfileSync.answer(single, in: bucket)

        #expect(ProfileSync.openQuestions(from: bucket) == [other])
    }

    /// A device that has never synced carries no question.
    @Test("No sync, no questions")
    func noQuestionsWithoutSync() {
        #expect(ProfileSync.openQuestions(from: InMemoryStore()).isEmpty)
    }

    // MARK: - The whole chain

    /// **The case my first four checks did not catch.**
    ///
    /// They saw the computation (`merge`) and the store (`memorize`), but not the
    /// **connection** — and that was the finding: The open pairs arose and nobody
    /// picked them up. The counter-check stayed green although the remembering was removed. The whole
    /// process is therefore checked.
    @Test("The operation stores the book and the open question together")
    func operationFilesBoth() {
        let bucket = InMemoryStore()
        let here = Profile(name: "Max", credentials: [Self.account("max")])
        ProfileBook(profile: [here], active: here.identifier).write(in: bucket)

        let there = Profile(name: "Papa", credentials: [Self.account("max")])
        ProfileSync.adopt(cloud: [there], in: bucket)

        // Both profiles stay — "unclear stays two".
        #expect(ProfileBook.read(from: bucket).profile.count == 2)
        // And the question stands too, otherwise nobody learns why there are two.
        #expect(ProfileSync.openQuestions(from: bucket).count == 1)
    }

    /// **And whoever is watching stays the same** — through the whole chain, not only in
    /// the computation.
    @Test("The operation carries the active identifier along")
    func operationCarriesActive() {
        let bucket = InMemoryStore()
        let childProfile = Profile(name: "Selin", kind: .kind)
        let max = Profile(name: "Max")
        // The child profile comes first: Without migrating along, "active" would fall back to it.
        ProfileBook(profile: [childProfile, max], active: max.identifier).write(in: bucket)

        ProfileSync.adopt(cloud: [Profile(name: "Max")], in: bucket)

        #expect(ProfileBook.read(from: bucket).activeProfile?.name == "Max")
    }

    /// A cloud without profiles changes nothing — and stores no empty question either.
    @Test("An empty cloud leaves everything in place")
    func emptyCloudChangesNothing() {
        let bucket = InMemoryStore()
        let here = Profile(name: "Max")
        ProfileBook(profile: [here], active: here.identifier).write(in: bucket)

        #expect(ProfileSync.adopt(cloud: [], in: bucket) == 0)
        #expect(ProfileBook.read(from: bucket).profile.count == 1)
        #expect(ProfileSync.openQuestions(from: bucket).isEmpty)
    }

    /// **The question stands at both circles and not at one.**
    ///
    /// It reads "are these two people or one?". Whoever marked only one side would leave
    /// open **which** other one the profile belongs with — and with three profiles that
    /// cannot be guessed.
    @Test("Both sides of a pair carry the question")
    func bothSidesCarryTheQuestion() {
        let here = Profile.Identifier.fresh()
        let there = Profile.Identifier.fresh()
        let foreign = Profile.Identifier.fresh()
        let pairs = [ProfileSync.Pair(device: here, cloud: there)]

        #expect(ProfileSync.isInQuestion(here, under: pairs))
        #expect(ProfileSync.isInQuestion(there, under: pairs))
        #expect(!ProfileSync.isInQuestion(foreign, under: pairs))
    }

    /// Without open pairs nobody carries a token — otherwise it would stand at every circle.
    @Test("Without questions no profile carries a mark")
    func noBrandWithoutQuestions() {
        #expect(!ProfileSync.isInQuestion(.fresh(), under: []))
    }
}
