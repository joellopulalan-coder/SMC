import Foundation

/// Returns the translation of `key` from `Localizable.strings`, falling back to the English key.
///
/// Every user-facing string in the app goes through this function so that
/// `Scripts/check_localization.py` can verify that each one has a translation.
/// Placeholders are always `%@` and arguments are always strings.
func tr(_ key: String, _ args: String...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { $0 as CVarArg })
}
