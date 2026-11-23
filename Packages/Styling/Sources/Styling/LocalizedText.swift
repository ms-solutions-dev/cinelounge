import Core
import SwiftUI

extension Text {

    /// A translated text from within a package.
    ///
    /// **One version for both devices** (AP58, 2026-09-26): Until then this file existed in
    /// both design packages, identical except for the comments.
    ///
    /// Necessary because `Text("key")` within a package looks up in the **package bundle**,
    /// not in the app's — and the string catalog lives with the app target
    /// (`App/Resources/Localizable.xcstrings`). Without this specification the
    /// key name appears untranslated on the screen, and nothing fails in the process.
    /// In the TV programme this has happened twice, with 17 and with 20 keys.
    ///
    /// **From the catalog that carries the key** (AP58 final step): Since shared
    /// wordings are in the catalog `WordingKit`, a key here can come from either.
    /// Which one carries it is decided by ``Core/AppLanguageSetting/catalog(forItem:)`` at the key itself
    /// (``SwiftUICore/LocalizedStringKey/catalogKey``); without a key the app's applies.
    public init(app key: LocalizedStringKey) {
        self.init(key, bundle: key.catalog)
    }

    /// The same for a key that only comes into being at runtime.
    ///
    /// **From the catalog that carries the key** (AP58 R3): A key that travels as a
    /// value — the sentence of a state, a refusal — can come from the shared
    /// catalog `WordingKit`. Looking it up here only in the app's catalog would mean
    /// showing its name on the device.
    ///
    /// For example `Text(appKey: "state." + state.rawValue)`. `scripts/strings.py` cannot see such
    /// keys and therefore reports them as orphaned — that is a hint,
    /// not an error.
    public init(appKey key: String) {
        self.init(LocalizedStringKey(key), bundle: AppLanguageSetting.catalog(forItem: key))
    }
}

extension Label where Title == Text, Icon == Image {

    /// Label and icon, translated from the app bundle.
    public init(app key: LocalizedStringKey, systemImage name: String) {
        self.init {
            Text(app: key)
        } icon: {
            Image(systemName: name)
        }
    }
}

extension LocalizedStringKey {

    /// The catalog key — `"a.b %lld"` for `"a.b \(3)"`.
    ///
    /// **Via `Mirror`, because SwiftUI does not make it public.** The check
    /// `CatalogChoiceTests` records that the reflection delivers it; if Apple changes the field,
    /// it shows up there, and on the device the app's catalog applies until then.
    public var catalogKey: String? {
        Mirror(reflecting: self).children.first { $0.label == "key" }?.value as? String
    }

    /// The bundle whose catalog carries this key — the shared one or the app's.
    public var catalog: Bundle {
        catalogKey.map(AppLanguageSetting.catalog(forItem:)) ?? .main
    }
}
