import Foundation

/// The SDK ships its own `Localizable.xcstrings`, so every user-facing string
/// has to resolve against *this package's* resource bundle. The host app's main
/// bundle - the default for `Text("…")`, `Button("…")`, `LocalizedStringResource`
/// and friends - has never heard of these keys, and would render them raw.
///
/// SwiftUI views say `Text("…", bundle: .module)` inline. The helpers below
/// cover the paths where a string has to be carried around as a value before it
/// reaches a view.
extension Bundle {
    /// The bundle holding the SDK's String Catalog.
    ///
    /// An explicit alias for SwiftPM's generated `Bundle.module`, so code
    /// outside this target - the test target, which gets a `Bundle.module` of
    /// its own the moment it gains any resource - can name *this* bundle
    /// unambiguously.
    static var feedbackThread: Bundle { .module }
}

extension LocalizedStringResource {
    /// A key from the SDK's own String Catalog.
    static func feedbackThread(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.feedbackThread.bundleURL))
    }

    /// A key from the SDK's own String Catalog whose key and English text differ.
    ///
    /// Needed only where the English text is nothing but format specifiers:
    /// Xcode's catalog symbol generator can't derive a Swift identifier from a
    /// key like `"%@ (%lld)"` and fails the build, so such a string gets a
    /// symbolic key and carries its English text as the default value.
    static func feedbackThread(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            key,
            defaultValue: defaultValue,
            bundle: .atURL(Bundle.feedbackThread.bundleURL)
        )
    }

    /// A runtime string carried through untouched: a message the server wrote,
    /// or a request status this SDK version doesn't recognize yet.
    ///
    /// The key is `"%@"` and the string itself is its argument, so the value is
    /// never looked up in a catalog and can never be shadowed by a translation.
    /// `"%@"` is deliberately absent from the SDK's catalog, so the lookup always
    /// falls through to plain substitution and yields the value verbatim.
    static func feedbackThreadVerbatim(_ value: String) -> LocalizedStringResource {
        LocalizedStringResource("\(value)", bundle: .atURL(Bundle.feedbackThread.bundleURL))
    }
}
