import Foundation

/// The characters that separate pieces of information from one another.
///
/// **In one place and outside the view.** The separator dot stood in `MetaRow` and thus
/// in a `View` — that is, bound to `@MainActor`. When a source needed it to assemble
/// "H.264 · HDR · MKV", it was unreachable from there, and the obvious answer would have
/// been a second `" · "` at the second place. Two spellings of the same character are the
/// beginning of three.
///
/// **Thin spaces around the dot** (U+2009): An ordinary space makes the separator look like
/// a word of its own, none at all glues it to the number before it.
public enum DelimiterChars {

    /// „2019 · FSK 12 · Anime"
    public static let point = " · "
}
