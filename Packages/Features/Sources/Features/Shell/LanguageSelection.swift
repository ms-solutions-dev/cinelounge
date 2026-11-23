import Foundation

/// Access to the app's language choice.
///
/// Phrased as a contract so that the views need not know how and where
/// the choice is stored — that belongs to the app target, not here.
public protocol LanguageSelection: AnyObject {

    /// Identifier of the currently selected language, e.g. `"de"`.
    var currentCode: String { get }

    /// The selectable languages, each with the name it gives
    /// itself — a Turkish user looks for "Türkçe", not "Türkisch".
    var available: [(code: String, endonym: String)] { get }

    func select(_ code: String)
}
