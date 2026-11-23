import Foundation

/// A person on a title.
///
/// **A type of its own and not `Core.Person`.** The shared type carries what the media
/// server delivers; on the detail page two things are added that it cannot know — the
/// fetched portrait from the film database and the German voice from AniList. Both are
/// additions that arrive after the page already stands; they therefore belong in a value
/// that the view can replace without touching the server state.
public struct PersonDetail: Sendable, Equatable, Identifiable {

    /// **Only actors and directors stand in the circle.** Production and music rarely interest
    /// in the living room — the same rule as on the TV (`Person.Role.isProminent`), except that
    /// here it decides over the task and not over the focus.
    public enum Role: String, Sendable, Equatable, Codable, CaseIterable {
        case cast = "darsteller"
        case directors = "regie"
        case ledger = "buch"
        case other = "sonstige"

        /// The key in the catalog — as a heading above the group.
        public var titleKey: String {
            switch self {
            case .cast: "cast.actors"
            case .directors: "cast.directors"
            case .ledger: "cast.writers"
            case .other: "cast.others"
            }
        }
    }

    public let id: String
    public let name: String

    /// The character played, where the server carries it.
    ///
    /// For anime, "Spautrol Riaskupit" is the more interesting piece of information than the name of
    /// the voice actress — and it is at the same time the **only** reliable key to the German
    /// voice; see ``RatingsKit/GermanVoices``.
    public let characterName: String?

    public let task: Role

    /// The media server's image. `nil` means: It carries none for this person.
    public let image: URL?

    /// The German voice for this role — supplied later, where AniList carries it.
    public var voiceActor: String?

    /// The portrait fetched from the film database.
    ///
    /// **Only the substitute, never the preference:** The media server's image fits the title,
    /// the fetched one is a name search and can miss when names are identical.
    public var portrait: URL?

    /// What is shown — your own first.
    public var imageAddress: URL? { image ?? portrait }

    public init(
        id: String, name: String, characterName: String? = nil, task: Role = .cast,
        image: URL? = nil, voiceActor: String? = nil, portrait: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.characterName = characterName
        self.task = task
        self.image = image
        self.voiceActor = voiceActor
        self.portrait = portrait
    }
}
