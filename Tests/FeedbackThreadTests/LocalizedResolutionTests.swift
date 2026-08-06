import Foundation
import Testing
@testable import FeedbackThread

/// Every string the SDK hands a view has to be looked up in the SDK's *own*
/// bundle. If one is built against the host app's bundle instead, the lookup
/// misses and Foundation falls back to the key - which, for a catalog keyed by
/// its English text, is the English text. The mistake is invisible in English
/// and shows up as an untranslated app everywhere else.
///
/// So this suite compares each resource against an expectation built directly
/// from ``Bundle/feedbackThread``, never by calling the same helper the code
/// under test calls. Two resources are equal only when their key, table, locale
/// *and* bundle match, so a misrouted helper fails here - in every environment,
/// with no compiled resources required.
@Suite("String resource routing")
struct StringResourceRoutingTests {
    /// Built without going through `LocalizedStringResource.feedbackThread(_:)`,
    /// so that helper can't vouch for itself.
    static func expected(_ key: String) -> LocalizedStringResource {
        LocalizedStringResource(
            String.LocalizationValue(stringLiteral: key),
            bundle: .atURL(Bundle.feedbackThread.bundleURL)
        )
    }

    /// The same, for the `"%@"` format the verbatim passthrough travels through.
    static func expectedVerbatim(_ value: String) -> LocalizedStringResource {
        LocalizedStringResource("\(value)", bundle: .atURL(Bundle.feedbackThread.bundleURL))
    }

    @Test("Resolves against the package's bundle, not the host app's")
    func packageBundleIsNotTheMainBundle() {
        #expect(Bundle.feedbackThread != Bundle.main)
        #expect(Bundle.feedbackThread.bundleURL != Bundle.main.bundleURL)
    }

    @Test(
        "Routes every recognized request status to the package bundle",
        arguments: [
            ("Submitted", "Waiting for review"),
            ("Under review", "In review"),
            ("In review", "In review"),
            ("Planned", "Planned"),
            ("In progress", "In progress"),
            ("Ready to release", "In progress"),
            ("Released", "Completed"),
            ("Rejected", "Rejected"),
        ]
    )
    func statusLabelRouting(status: String, key: String) {
        #expect(status.feedbackThreadRequestLabel == Self.expected(key))
    }

    @Test("Routes feedback kinds and the watchOS target to the package bundle")
    func titleRouting() {
        #expect(FeedbackThreadFeedbackKind.bug.localizedTitle == Self.expected("Bug"))
        #expect(FeedbackThreadFeedbackKind.request.localizedTitle == Self.expected("Request"))
        #expect(FeedbackThreadFeedbackKind.review.localizedTitle == Self.expected("Review"))
        #expect(FeedbackThreadRequestTarget.watchOS.localizedTitle == Self.expected("Apple Watch"))
        #expect(FeedbackThreadRequestTarget.ios.localizedTitle == nil)
        #expect(FeedbackThreadRequestTarget.android.localizedTitle == nil)
    }

    @Test("Routes an unrecognized status through the verbatim format, still in the package bundle")
    func verbatimRouting() {
        // The key is "%@" and the status is its argument, so a server-invented
        // value is never looked up - but the bundle still has to be ours, or the
        // host app could translate "%@" and rewrite every passthrough.
        let label = "archived".feedbackThreadRequestLabel
        #expect(label.key == "%@")
        #expect(label == Self.expectedVerbatim("Archived"))
    }

    @Test("Keeps the public English titles untouched")
    func publicTitlesAreUnchanged() {
        #expect(FeedbackThreadFeedbackKind.bug.title == "Bug")
        #expect(FeedbackThreadFeedbackKind.request.title == "Request")
        #expect(FeedbackThreadFeedbackKind.review.title == "Review")
        #expect(FeedbackThreadRequestTarget.watchOS.title == "Apple Watch")
        #expect(FeedbackThreadRequestTarget.ios.title == nil)
    }
}

/// The translations themselves, read out of the built bundle's compiled `.lproj`.
///
/// Asserting Italian rather than English is the point: English equals the key, so
/// an English-only expectation passes even when nothing resolved at all. "Rifiutata"
/// can only come from the catalog.
///
/// Skipped where the build system didn't compile the catalog - see ``CompiledCatalog``.
@Suite(
    "Localized resolution",
    .enabled(if: CompiledCatalog.isAvailable, .init(rawValue: CompiledCatalog.unavailableReason))
)
struct LocalizedResolutionTests {
    /// Fails loudly on a missing key rather than quietly comparing nil.
    static func resolve(_ key: String, in language: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(
            CompiledCatalog.string(key, in: language),
            "\"\(key)\" is not in the compiled \(language) catalog",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Request status labels

    @Test(
        "Resolves every recognized request status in Italian",
        arguments: [
            ("Submitted", "In attesa di revisione"),
            ("Under review", "In revisione"),
            ("In review", "In revisione"),
            ("Planned", "Pianificata"),
            ("In progress", "In corso"),
            ("Ready to release", "In corso"),
            ("Released", "Completata"),
            ("Rejected", "Rifiutata"),
        ]
    )
    func statusLabelsInItalian(status: String, italian: String) throws {
        let resource = status.feedbackThreadRequestLabel
        #expect(try #require(CompiledCatalog.string(resource, in: "it")) == italian)
    }

    @Test(
        "Resolves every recognized request status in English",
        arguments: [
            ("Submitted", "Waiting for review"),
            ("Planned", "Planned"),
            ("Released", "Completed"),
            ("Rejected", "Rejected"),
        ]
    )
    func statusLabelsInEnglish(status: String, english: String) throws {
        let resource = status.feedbackThreadRequestLabel
        #expect(try #require(CompiledCatalog.string(resource, in: "en")) == english)
    }

    @Test("Never puts an unrecognized status in the catalog, in any language")
    func unknownStatusIsNeverTranslated() throws {
        // "Archived" is what `sensiblyCapitalized` makes of the server's value.
        // It must not exist as a key, or a translation could rewrite it.
        for language in LocalizationCatalogTests.catalogLanguages {
            #expect(CompiledCatalog.string("Archived", in: language) == nil)
            #expect(CompiledCatalog.string("On Hold", in: language) == nil)
            // The format it *does* travel through must stay absent too.
            #expect(CompiledCatalog.string("%@", in: language) == nil)
        }
    }

    // MARK: - Public titles

    @Test("Resolves feedback kinds and the watchOS target in Italian")
    func titlesInItalian() throws {
        #expect(try #require(CompiledCatalog.string(FeedbackThreadFeedbackKind.bug.localizedTitle, in: "it")) == "Bug")
        #expect(try #require(CompiledCatalog.string(FeedbackThreadFeedbackKind.request.localizedTitle, in: "it")) == "Richiesta")
        #expect(try #require(CompiledCatalog.string(FeedbackThreadFeedbackKind.review.localizedTitle, in: "it")) == "Recensione")

        // A brand name: identical in both languages, but it still has to come
        // from the catalog rather than fall back to the key.
        let watch = try #require(FeedbackThreadRequestTarget.watchOS.localizedTitle)
        #expect(try #require(CompiledCatalog.string(watch, in: "it")) == "Apple Watch")
    }

    // MARK: - Formats and plurals

    @Test("Resolves the shipped-in badge in Italian, keeping the version verbatim")
    func shippedInBadgeInItalian() throws {
        #expect(CompiledCatalog.format("Shipped in %@", "2.4.0", in: "it") == "Rilasciata nella versione 2.4.0")
        #expect(CompiledCatalog.format("Shipped in %@", "2.4.0", in: "en") == "Shipped in 2.4.0")
    }

    @Test("Resolves the filter chip's symbolic key in Italian")
    func filterChipInItalian() throws {
        // A symbolic key, so its English text is a real translation rather than
        // the key echoed back - which makes it the one entry where even the
        // English assertion proves a lookup happened.
        let italian = try Self.resolve("filter.chip", in: "it")
        #expect(italian == "%@ (%lld)")
        #expect(String(format: italian, locale: Locale(identifier: "it"), try Self.resolve("Planned", in: "it"), 12) == "Pianificata (12)")
    }

    @Test(
        "Picks the right plural for the votes accessibility value",
        arguments: [
            ("it", 0, "0 voti"),
            ("it", 1, "1 voto"),
            ("it", 2, "2 voti"),
            ("it", 34, "34 voti"),
            ("en", 1, "1 vote"),
            ("en", 34, "34 votes"),
        ]
    )
    func votesPlural(language: String, votes: Int, expected: String) throws {
        #expect(CompiledCatalog.plural("%lld votes", count: votes, in: language) == expected)
    }

    // MARK: - Errors

    @Test("Resolves the two end-user error messages in Italian")
    func errorMessagesInItalian() throws {
        #expect(
            try Self.resolve("FeedbackThread returned an unreadable response.", in: "it")
                == "FeedbackThread ha restituito una risposta illeggibile."
        )
        #expect(
            CompiledCatalog.plural("FeedbackThread returned HTTP %lld.", count: 503, in: "it")
                == "FeedbackThread ha restituito il codice HTTP 503."
        )
    }

    // MARK: - A representative sweep of view copy

    @Test(
        "Resolves the drop-in views' copy in Italian",
        arguments: [
            ("Done", "Fine"),
            ("Cancel", "Annulla"),
            ("Feature requests", "Richieste di funzionalità"),
            ("My requests", "Le mie richieste"),
            ("Suggest a feature", "Suggerisci una funzionalità"),
            ("Send feedback", "Invia feedback"),
            ("Try again", "Riprova"),
            ("All", "Tutte"),
            ("Waiting for review", "In attesa di revisione"),
            ("Shipped", "Rilasciate"),
            ("Closed", "Chiuse"),
            ("Vote", "Vota"),
            ("Remove vote", "Rimuovi il voto"),
            ("No planned requests", "Nessuna richiesta pianificata"),
            ("Request submitted for review.", "Richiesta inviata per la revisione."),
        ]
    )
    func viewCopyInItalian(key: String, italian: String) throws {
        #expect(try Self.resolve(key, in: "it") == italian)
    }
}

/// Error copy that must survive untranslated, whatever the build system did.
@Suite("Error passthrough")
struct ErrorPassthroughTests {
    @Test("Leaves integrator-facing and server-supplied errors alone")
    func passthroughErrorsAreNotTranslated() {
        // Configuration errors address the developer wiring the SDK up, so they
        // are English by design and carry no catalog key.
        let configuration = FeedbackThreadError.invalidConfiguration("A FeedbackThread project key is required.")
        #expect(configuration.errorDescription == "A FeedbackThread project key is required.")

        // The API wrote this one; the SDK must not reinterpret it.
        let server = FeedbackThreadError.server(statusCode: 429, message: "Troppe richieste")
        #expect(server.errorDescription == "Troppe richieste")
    }
}
