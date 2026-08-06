import Foundation
@testable import FeedbackThread

/// Reads the SDK's translations back out of the *built* resource bundle, going
/// straight to a language's compiled `.lproj` rather than asking Foundation to
/// pick one.
///
/// Nothing here negotiates a locale. `Bundle.preferredLocalizations`,
/// `Locale.current`, and `LocalizedStringResource.locale` all answer differently
/// depending on the machine, the toolchain, and the host app's language list, so
/// a test that leans on any of them asserts the environment rather than the
/// catalog. Naming the `.lproj` directly is the same lookup in every
/// environment: pick the language, read the key, done.
///
/// ## Why this can be absent
///
/// SwiftPM's *native* build system - the default through Swift 6.3, and what
/// `swift test` uses on the CI runner - copies `Localizable.xcstrings` into the
/// resource bundle verbatim instead of compiling it into `.lproj/Localizable.strings`
/// and `Localizable.stringsdict`. In such a build *nothing* is localized, English
/// included: every lookup misses and falls back to the raw key, so `"%lld votes"`
/// renders as "1 votes".
///
/// Xcode's build system compiles the catalog, as does SwiftPM's `swiftbuild`
/// engine (the default from Swift 6.4). Xcode's is the path a host app actually
/// integrates through, so the shipped SDK is unaffected - this is a limitation of
/// one build engine, not of the package. Tests that need real translations are
/// gated on ``isAvailable`` so they exercise the catalog wherever it exists and
/// skip, loudly, where the build system never produced it.
enum CompiledCatalog {
    static let table = "Localizable"

    /// Distinguishes "this key is missing" from "this key's value happens to
    /// equal its key", which is the common case in the source language.
    private static let missing = "\u{0}FeedbackThread.missing"

    /// The compiled `.lproj` sub-bundle for a language, or nil when this build
    /// system didn't compile the catalog.
    static func bundle(for language: String) -> Bundle? {
        guard let path = Bundle.feedbackThread.path(forResource: language, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    /// Whether this build compiled the catalog at all.
    static var isAvailable: Bool { bundle(for: "en") != nil }

    /// Named in the skip message so a green CI run still says why these didn't run.
    static let unavailableReason = """
        This build system copied Localizable.xcstrings into the resource bundle \
        instead of compiling it, so no translation is loadable (SwiftPM's native \
        build engine, default through Swift 6.3). Run `swift test --build-system \
        swiftbuild`, or build through Xcode, to exercise these.
        """

    /// The value for `key` in `language`, or nil when the key is absent.
    static func string(_ key: String, in language: String) -> String? {
        guard let bundle = bundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        return value == missing ? nil : value
    }

    /// The value for a resource the SDK produced, looked up by its catalog key.
    static func string(_ resource: LocalizedStringResource, in language: String) -> String? {
        string(resource.key, in: language)
    }

    /// A plural-bearing key rendered for `count`.
    ///
    /// The compiled form of a plural lives in `Localizable.stringsdict` and comes
    /// back as a `%#@…@` rule, which only expands through `String(format:)`. The
    /// locale is passed explicitly so the plural *category* is chosen by the
    /// language under test, not by whatever the machine is set to.
    static func plural(_ key: String, count: Int, in language: String) -> String? {
        guard let format = string(key, in: language) else { return nil }
        return String(format: format, locale: Locale(identifier: language), count)
    }

    /// A format-bearing key rendered with one string argument.
    static func format(_ key: String, _ argument: String, in language: String) -> String? {
        guard let format = string(key, in: language) else { return nil }
        return String(format: format, locale: Locale(identifier: language), argument)
    }
}
