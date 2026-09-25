import Foundation

/// Shorthand for localized string lookup. English-only — looks up directly in the
/// main bundle's `en.lproj/Localizable.strings`.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
