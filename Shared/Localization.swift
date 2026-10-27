import Foundation

/// Localizes app-owned text at its origin. Filenames, device names and wire diagnostics
/// remain data; they are never used as localization keys.
enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Object placeholders support positional reordering without exposing format types.
    static func format(
        _ key: String, _ arguments: String..., bundle: Bundle = .main, locale: Locale = .current
    ) -> String {
        String(format: text(key, bundle: bundle), locale: locale, arguments: arguments)
    }
}
