/// The ground `Core` stands on — re-exported, so that the forty
/// places in TV and phone that write `import Core` still see `SecureStore`,
/// `Diagnostics` or `Theme` without a second import.
///
/// **Why `@_exported` and not forty import lines** (StoryShelf AP1,
/// 2026-09-17): The split should touch no file in either program
/// that has nothing to do with it. Should it ever cause ambiguities —
/// the `NetworkWatch` duplication of 2026-09-11 was such a case —, the way out is
/// known: delete the line here and spell out the imports there.
@_exported import Grundstock
