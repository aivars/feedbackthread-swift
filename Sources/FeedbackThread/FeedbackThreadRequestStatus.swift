import Foundation

/// The canonical stages of the public feature-request board.
///
/// Statuses the SDK doesn't recognize are preserved as ``unknown(_:)`` rather
/// than dropped, so a status added on the server later doesn't silently hide
/// cards from a board built against an older SDK.
enum FeedbackThreadRequestStage: Equatable, Sendable {
    /// Submitted, not yet moderated - only ever seen by the reporter (see
    /// FeedbackThreadClient.myRequests), never on the public board.
    case pendingReview
    case inReview
    case planned
    case inProgress
    case completed
    /// Declined during moderation - only ever seen by the reporter, same as
    /// ``pendingReview``.
    case rejected
    case unknown(String)
}

/// Which section of the "My requests" list a status belongs in. A pure,
/// exhaustive mapping - kept outside the `#if os(iOS)`-gated view files so
/// it's directly testable, and so every stage (including ones the SDK
/// doesn't recognize yet) is guaranteed to land in exactly one section
/// rather than being silently dropped.
enum FeedbackThreadMyRequestsSection: Equatable, Sendable {
    case waitingForReview
    case inProgress
    case shipped
    case closed
}

extension FeedbackThreadRequestStage {
    /// Buckets this stage into its "My requests" section. Unknown stages
    /// fold into ``FeedbackThreadMyRequestsSection/inProgress`` (their raw
    /// status label still renders via ``String/feedbackThreadRequestLabel``)
    /// so a status the SDK doesn't recognize yet doesn't produce a card that
    /// fits no section and effectively vanishes from the list.
    var feedbackThreadMyRequestsSection: FeedbackThreadMyRequestsSection {
        switch self {
        case .pendingReview: .waitingForReview
        case .inReview, .planned, .inProgress, .unknown: .inProgress
        case .completed: .shipped
        case .rejected: .closed
        }
    }
}

extension String {
    /// Maps a raw feature-request status string to its public board stage.
    var feedbackThreadRequestStage: FeedbackThreadRequestStage {
        switch self {
        case "Submitted": .pendingReview
        case "Under review", "In review": .inReview
        case "Planned": .planned
        case "In progress", "Ready to release": .inProgress
        case "Released": .completed
        case "Rejected": .rejected
        default: .unknown(self)
        }
    }

    /// A user-facing label for the status: the known stage's display name from
    /// the SDK's String Catalog, or the raw status sensibly capitalized when the
    /// stage isn't recognized.
    ///
    /// Note that the recognized labels are *display* strings that happen to read
    /// like the wire values matched in ``feedbackThreadRequestStage`` above. They
    /// are translated; the wire values never are.
    ///
    /// The unrecognized case stays a verbatim passthrough: a status this SDK
    /// version doesn't know is a value the server invented, so it has no
    /// translation and must not be looked up as a catalog key.
    var feedbackThreadRequestLabel: LocalizedStringResource {
        switch feedbackThreadRequestStage {
        case .pendingReview: .feedbackThread("Waiting for review")
        case .inReview: .feedbackThread("In review")
        case .planned: .feedbackThread("Planned")
        case .inProgress: .feedbackThread("In progress")
        case .completed: .feedbackThread("Completed")
        case .rejected: .feedbackThread("Rejected")
        case .unknown: .feedbackThreadVerbatim(sensiblyCapitalized)
        }
    }

    /// Capitalizes each word of a raw status string, e.g. "on_hold" -> "On Hold".
    var sensiblyCapitalized: String {
        let words = replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        guard !words.isEmpty else { return self }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
