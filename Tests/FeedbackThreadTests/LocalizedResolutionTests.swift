import Foundation
import Testing
@testable import FeedbackThread

/// Resolves the SDK's own strings against the *compiled* package bundle, in a
/// pinned locale, and asserts the exact Italian text.
///
/// This is what proves the bundle routing is right, and it is deliberately not
/// expressible as "the label equals the catalog value for the same key": that
/// comparison holds even when a resource is misrouted to `Bundle.main`, because
/// a failed lookup falls back to the key, and the key *is* the English text.
/// Pinning Italian breaks that symmetry — a misrouted resource yields "Rejected"
/// where this suite demands "Rifiutata".
///
/// It also means these assertions hold no matter what language the machine
/// running the tests is set to.
@Suite("Localized resolution")
struct LocalizedResolutionTests {
    /// Resolves a resource produced by the SDK in a specific language.
    ///
    /// Only the locale is overridden — the bundle travels with the resource,
    /// exactly as the SDK's own views receive it — so a resource pointing at the
    /// wrong bundle resolves to its key here and fails the expectation.
    static func resolve(_ resource: LocalizedStringResource, in identifier: String) -> String {
        var localized = resource
        localized.locale = Locale(identifier: identifier)
        return String(localized: localized)
    }

    /// Resolves a catalog key the same way the SDK's helper does.
    static func resolve(key: String.LocalizationValue, in identifier: String) -> String {
        resolve(.feedbackThread(key), in: identifier)
    }

    /// Resolves a key that arrives as a runtime value — a row of a test table
    /// rather than a literal in the call. Writing `"\(rawKey)"` instead would
    /// build the `"%@"` format and look *that* up, quietly passing on every row.
    static func resolve(rawKey: String, in identifier: String) -> String {
        resolve(key: String.LocalizationValue(stringLiteral: rawKey), in: identifier)
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
    func statusLabelsInItalian(status: String, italian: String) {
        #expect(Self.resolve(status.feedbackThreadRequestLabel, in: "it") == italian)
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
    func statusLabelsInEnglish(status: String, english: String) {
        #expect(Self.resolve(status.feedbackThreadRequestLabel, in: "en") == english)
    }

    @Test("Leaves an unrecognized status untranslated in every language")
    func unknownStatusIsNeverTranslated() {
        // "Archived" is not in the catalog and must not become one: a status the
        // server invented has to survive the trip in every locale — including
        // any language added to the catalog after this was written.
        for language in LocalizationCatalogTests.catalogLanguages {
            #expect(Self.resolve("archived".feedbackThreadRequestLabel, in: language) == "Archived")
            #expect(Self.resolve("on_hold".feedbackThreadRequestLabel, in: language) == "On Hold")
        }
    }

    // MARK: - Public titles

    @Test("Resolves feedback kinds and the watchOS target in Italian")
    func titlesInItalian() {
        #expect(Self.resolve(FeedbackThreadFeedbackKind.bug.localizedTitle, in: "it") == "Bug")
        #expect(Self.resolve(FeedbackThreadFeedbackKind.request.localizedTitle, in: "it") == "Richiesta")
        #expect(Self.resolve(FeedbackThreadFeedbackKind.review.localizedTitle, in: "it") == "Recensione")

        // A brand name: identical in both languages, but it must still come from
        // the catalog rather than fall back to the key.
        let watch = FeedbackThreadRequestTarget.watchOS.localizedTitle
        #expect(watch.map { Self.resolve($0, in: "it") } == "Apple Watch")

        // The public English titles are untouched by any of this.
        #expect(FeedbackThreadFeedbackKind.request.title == "Request")
        #expect(FeedbackThreadRequestTarget.watchOS.title == "Apple Watch")
    }

    // MARK: - Formats and plurals

    @Test("Resolves the shipped-in badge in Italian, keeping the version verbatim")
    func shippedInBadgeInItalian() {
        #expect(Self.resolve(key: "Shipped in \("2.4.0")", in: "it") == "Rilasciata nella versione 2.4.0")
        #expect(Self.resolve(key: "Shipped in \("2.4.0")", in: "en") == "Shipped in 2.4.0")
    }

    @Test("Resolves the filter chip's symbolic key in Italian")
    func filterChipInItalian() {
        let chip = LocalizedStringResource.feedbackThread(
            "filter.chip",
            defaultValue: "\(Self.resolve(key: "Planned", in: "it")) (\(12))"
        )
        #expect(Self.resolve(chip, in: "it") == "Pianificata (12)")
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
    func votesPlural(language: String, votes: Int, expected: String) {
        #expect(Self.resolve(key: "\(votes) votes", in: language) == expected)
    }

    // MARK: - Errors

    @Test("Resolves the two end-user error messages in Italian")
    func errorMessagesInItalian() {
        #expect(
            Self.resolve(key: "FeedbackThread returned an unreadable response.", in: "it")
                == "FeedbackThread ha restituito una risposta illeggibile."
        )
        #expect(
            Self.resolve(key: "FeedbackThread returned HTTP \(503).", in: "it")
                == "FeedbackThread ha restituito il codice HTTP 503."
        )
    }

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
    func viewCopyInItalian(key: String, italian: String) {
        #expect(Self.resolve(rawKey: key, in: "it") == italian)
    }
}
