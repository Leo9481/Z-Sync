import Foundation
import Observation
import Translation

/// The Translation section of Settings: which language pages are translated
/// into, which languages are never translated automatically, and whether
/// pages in other languages translate on their own as they open.
@MainActor
@Observable
final class TranslationSettings {
    static let shared = TranslationSettings()

    private enum Key {
        static let target = "translation.target"
        static let never = "translation.never"
        static let auto = "translation.auto"
    }

    /// A language identifier (`it`, `en-GB`, `zh-Hant`), or nil for the
    /// phone's own language.
    var targetLanguage: String? {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Key.target) }
    }

    /// Language codes (`en`, `de`) that automatic translation leaves alone.
    /// Turning Translate on by hand still translates them.
    var neverTranslate: Set<String> {
        didSet { UserDefaults.standard.set(neverTranslate.sorted(), forKey: Key.never) }
    }

    var autoTranslate: Bool {
        didSet { UserDefaults.standard.set(autoTranslate, forKey: Key.auto) }
    }

    private init() {
        let defaults = UserDefaults.standard
        targetLanguage = defaults.string(forKey: Key.target)
        neverTranslate = Set(defaults.stringArray(forKey: Key.never) ?? [])
        autoTranslate = defaults.bool(forKey: Key.auto)
    }

    /// The language pages are translated into.
    var effectiveTarget: Locale.Language {
        Locale.Language(identifier: targetLanguage ?? Locale.preferredLanguages.first ?? "en")
    }

    func isNeverTranslated(_ code: String) -> Bool {
        neverTranslate.contains(code)
    }

    func setNeverTranslated(_ code: String, _ never: Bool) {
        if never { neverTranslate.insert(code) } else { neverTranslate.remove(code) }
    }

    /// A language's name in the reader's own language.
    static func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)?.localizedCapitalized ?? identifier
    }

    /// The languages Apple's on-device translation offers, as identifiers,
    /// sorted by name.
    static func supportedLanguages() async -> [String] {
        guard #available(iOS 18.0, *) else { return [] }
        let languages = await LanguageAvailability().supportedLanguages
        let identifiers = Set(languages.map(\.minimalIdentifier))
        return identifiers.sorted { displayName($0) < displayName($1) }
    }

    /// One entry per language code, for the never-translate list.
    static func languageCodes(of identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for identifier in identifiers {
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                  seen.insert(code).inserted else { continue }
            codes.append(code)
        }
        return codes.sorted { displayName($0) < displayName($1) }
    }
}
