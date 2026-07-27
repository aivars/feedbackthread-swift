import Foundation
import Testing
@testable import FeedbackThread

/// Guards the SDK's String Catalog against the two ways a translation quietly
/// rots: a key that gains a language but not a translated state, and a
/// translation whose format specifiers drift from the source language's (which
/// crashes at render time, not at build time).
///
/// The catalog is read from source rather than from `Bundle.module`: SwiftPM
/// compiles `Localizable.xcstrings` into per-language `.strings`/`.stringsdict`
/// files, so the authored catalog - the thing a contributor edits, and the thing
/// these invariants are about - is not in the built bundle at all. What *is*
/// checked against the bundle is that every language the catalog declares
/// actually ships.
///
/// The set of languages is derived from the catalog, never hardcoded here, so
/// adding one really is a change to `Localizable.xcstrings` and nothing else -
/// which is what the README promises. What the suite enforces is that the
/// languages stay *consistent*: whatever set the catalog uses, every single key
/// must cover it, and the built bundle must ship it.
@Suite("Localization catalog")
struct LocalizationCatalogTests {
    // MARK: - Model

    struct Catalog: Decodable, Sendable {
        let sourceLanguage: String
        let version: String
        let strings: [String: Entry]
    }

    struct Entry: Decodable, Sendable {
        let comment: String?
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable, Sendable {
        let stringUnit: StringUnit?
        let variations: Variations?

        /// Every unit this localization resolves to, singular or plural.
        var units: [StringUnit] {
            if let stringUnit { return [stringUnit] }
            guard let plural = variations?.plural else { return [] }
            return plural.values.compactMap(\.stringUnit)
        }
    }

    struct Variations: Decodable, Sendable {
        let plural: [String: Localization]?
    }

    struct StringUnit: Decodable, Sendable {
        let state: String
        let value: String
    }

    // MARK: - Loading

    /// The authored catalog, located relative to this file so the test works
    /// from any checkout.
    static let catalog: Catalog = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FeedbackThreadTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/FeedbackThread/Resources/Localizable.xcstrings")
        // Force-unwrapped on purpose: if the catalog can't be read the whole
        // suite is meaningless, and the crash names the missing file.
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Catalog.self, from: data)
    }()

    /// Every language the catalog mentions anywhere. Derived rather than
    /// declared: a contributor adding a language edits the catalog, and this set
    /// - and therefore what the rest of the suite demands - grows with it.
    static let catalogLanguages: Set<String> = Set(
        catalog.strings.values.flatMap { $0.localizations?.keys ?? [:].keys }
    )

    // MARK: - Tests

    @Test("Declares English as its source language")
    func sourceLanguage() {
        #expect(Self.catalog.sourceLanguage == "en")
        #expect(Self.catalog.version == "1.0")
    }

    @Test("Has at least one key")
    func isNotEmpty() throws {
        #expect(Self.catalog.strings.count > 40)
    }

    @Test("Declares a language set that includes its own source language")
    func languageSetIsCoherent() {
        #expect(!Self.catalogLanguages.isEmpty)
        #expect(
            Self.catalogLanguages.contains(Self.catalog.sourceLanguage),
            "the catalog declares \(Self.catalogLanguages.sorted()) but its source language is \(Self.catalog.sourceLanguage)"
        )
    }

    @Test("Translates every key into every language the catalog declares")
    func everyKeyIsFullyTranslated() throws {
        for (key, entry) in Self.catalog.strings.sorted(by: { $0.key < $1.key }) {
            let localizations = try #require(
                entry.localizations,
                "\"\(key)\" has no localizations at all"
            )
            // Equality, not containment: a key covering a *subset* is a missing
            // translation, and one covering a superset means the rest of the
            // catalog is behind. Either way the catalog is half-migrated.
            #expect(
                Set(localizations.keys) == Self.catalogLanguages,
                "\"\(key)\" covers \(Set(localizations.keys).sorted()), the catalog declares \(Self.catalogLanguages.sorted())"
            )

            for language in Self.catalogLanguages {
                let localization = try #require(
                    localizations[language],
                    "\"\(key)\" is missing \(language)"
                )
                let units = localization.units
                #expect(!units.isEmpty, "\"\(key)\" has no string unit for \(language)")
                for unit in units {
                    #expect(
                        unit.state == "translated",
                        "\"\(key)\" is \"\(unit.state)\" in \(language), not \"translated\""
                    )
                    #expect(
                        !unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\"\(key)\" is empty in \(language)"
                    )
                }
            }
        }
    }

    @Test("Keeps the same format specifiers in every language")
    func formatSpecifiersMatchAcrossLanguages() throws {
        for (key, entry) in Self.catalog.strings.sorted(by: { $0.key < $1.key }) {
            guard let localizations = entry.localizations else { continue }
            // The source-language text is the reference, not the key: a key is
            // allowed to be symbolic (see "filter.chip") while its English text
            // carries the specifiers.
            let english = try #require(localizations[Self.catalog.sourceLanguage])
            let source = try #require(english.units.first.map { Self.formatSpecifiers(in: $0.value) })
            for (language, localization) in localizations.sorted(by: { $0.key < $1.key }) {
                for unit in localization.units {
                    #expect(
                        Self.formatSpecifiers(in: unit.value) == source,
                        """
                        "\(key)" in \(language) has specifiers \
                        \(Self.formatSpecifiers(in: unit.value)), expected \(source)
                        """
                    )
                }
            }
        }
    }

    @Test("Gives the votes accessibility value a plural variation in every language")
    func votesUsesPlurals() throws {
        let entry = try #require(Self.catalog.strings["%lld votes"])
        let localizations = try #require(entry.localizations)
        for language in Self.catalogLanguages {
            let plural = try #require(
                localizations[language]?.variations?.plural,
                "\"%lld votes\" has no plural variation in \(language)"
            )
            #expect(plural["one"] != nil, "\"%lld votes\" is missing the 'one' category in \(language)")
            #expect(plural["other"] != nil, "\"%lld votes\" is missing the 'other' category in \(language)")
        }
    }

    @Test("Leaves \"%@\" out of the catalog, so verbatim strings stay verbatim")
    func verbatimFormatIsNotAKey() {
        // `LocalizedStringResource.feedbackThreadVerbatim(_:)` renders a runtime
        // value through the "%@" key. Translating that key would rewrite every
        // server message and unrecognized status the SDK passes through.
        #expect(Self.catalog.strings["%@"] == nil)
        #expect(String(localized: .feedbackThreadVerbatim("Nothing to see here")) == "Nothing to see here")
    }

    @Test("Ships every language the catalog declares in the built resource bundle")
    func bundleShipsEveryLanguage() {
        let shipped = Set(Bundle.feedbackThread.localizations)
        #expect(
            Self.catalogLanguages.isSubset(of: shipped),
            "the built bundle ships \(shipped.sorted()), the catalog declares \(Self.catalogLanguages.sorted())"
        )
    }

    @Test("Backs every recognized request status with a catalog key")
    func requestStatusLabelsExistInTheCatalog() {
        // The one place code and catalog are joined at runtime, so it is worth
        // pinning: every stage the SDK recognizes must resolve to a real key.
        for status in ["Submitted", "Under review", "In review", "Planned", "In progress", "Ready to release", "Released", "Rejected"] {
            let key = status.feedbackThreadRequestLabel.key
            #expect(
                Self.catalog.strings[key] != nil,
                "status \"\(status)\" labels as \"\(key)\", which is not in the catalog"
            )
        }
    }

    @Test("Backs every feedback kind and request target with a catalog key")
    func publicTitlesExistInTheCatalog() {
        for kind in FeedbackThreadFeedbackKind.allCases {
            #expect(
                Self.catalog.strings[kind.localizedTitle.key] != nil,
                "kind \(kind) labels as \"\(kind.localizedTitle.key)\", which is not in the catalog"
            )
            // The public `title` is unchanged English; the catalog key is that
            // same English, which is what keeps the two from drifting apart.
            #expect(kind.localizedTitle.key == kind.title)
        }

        let watch = FeedbackThreadRequestTarget.watchOS
        #expect(watch.localizedTitle?.key == watch.title)
        #expect(Self.catalog.strings["Apple Watch"] != nil)
        #expect(FeedbackThreadRequestTarget.ios.localizedTitle == nil)
        #expect(FeedbackThreadRequestTarget.android.localizedTitle == nil)
    }

    // MARK: - Helpers

    /// The format specifiers in a string, in order — e.g. `["%@", "%lld"]`.
    /// `%%` is an escaped literal percent and carries no argument.
    static func formatSpecifiers(in value: String) -> [String] {
        var specifiers: [String] = []
        var rest = Substring(value)
        while let percent = rest.firstIndex(of: "%") {
            var index = rest.index(after: percent)
            guard index < rest.endIndex else { break }
            if rest[index] == "%" {
                rest = rest[rest.index(after: index)...]
                continue
            }
            var specifier = "%"
            // Flags, width, precision, and length modifiers, then the conversion.
            while index < rest.endIndex, !"@dDuUxXoOfeEgGcCsSaAp".contains(rest[index]) {
                specifier.append(rest[index])
                index = rest.index(after: index)
            }
            if index < rest.endIndex {
                specifier.append(rest[index])
                index = rest.index(after: index)
            }
            specifiers.append(specifier)
            rest = rest[index...]
        }
        return specifiers
    }
}
