import Foundation
import Testing
@testable import FeedbackThread

@Suite("FeedbackThreadRequestStatus")
struct FeedbackThreadRequestStatusTests {
    @Test(
        "Maps known status strings to their public board stage",
        arguments: [
            ("Submitted", FeedbackThreadRequestStage.pendingReview),
            ("Under review", .inReview),
            ("In review", .inReview),
            ("Planned", .planned),
            ("In progress", .inProgress),
            ("Ready to release", .inProgress),
            ("Released", .completed),
            ("Rejected", .rejected),
        ]
    )
    func mapsKnownStatuses(status: String, stage: FeedbackThreadRequestStage) {
        #expect(status.feedbackThreadRequestStage == stage)
    }

    // Display labels are resolved through the SDK's String Catalog, so the
    // expectations resolve the same key the same way rather than hardcoding
    // English - otherwise these tests would only pass in an English locale.
    // The catalog key itself is asserted separately, which is what actually
    // pins the label to a specific piece of copy.

    @Test("Labels a Rejected status plainly")
    func labelsRejected() {
        #expect("Rejected".feedbackThreadRequestLabel.key == "Rejected")
        #expect(
            String(localized: "Rejected".feedbackThreadRequestLabel)
                == String(localized: "Rejected", bundle: .feedbackThread)
        )
    }

    @Test("Labels a Submitted status honestly, without implying moderation happened")
    func labelsPendingReview() {
        #expect("Submitted".feedbackThreadRequestLabel.key == "Waiting for review")
        #expect(
            String(localized: "Submitted".feedbackThreadRequestLabel)
                == String(localized: "Waiting for review", bundle: .feedbackThread)
        )
    }

    @Test("Preserves a fabricated, unrecognized status rather than dropping it")
    func preservesUnknownStatus() {
        let status = "archived"
        #expect(status.feedbackThreadRequestStage == .unknown("archived"))
        // A status this SDK version doesn't know is a value the server invented:
        // it has no translation and must come back exactly as capitalized, in
        // every locale.
        #expect(String(localized: status.feedbackThreadRequestLabel) == "Archived")
    }

    @Test("Sensibly capitalizes an unrecognized status with separators")
    func capitalizesUnknownStatusWithSeparators() {
        #expect(String(localized: "on_hold".feedbackThreadRequestLabel) == "On Hold")
        #expect(String(localized: "NEEDS-TRIAGE".feedbackThreadRequestLabel) == "Needs Triage")
    }

    @Test("Routes an unrecognized status around the catalog entirely")
    func unknownStatusNeverBecomesACatalogKey() {
        // The verbatim wrapper's key is the "%@" format, never the value, so a
        // server-invented status can't collide with (or be shadowed by) a
        // translated key.
        #expect("archived".feedbackThreadRequestLabel.key == "%@")
    }

    @Test(
        "Buckets every possible stage into exactly one My Requests section",
        arguments: [
            (FeedbackThreadRequestStage.pendingReview, FeedbackThreadMyRequestsSection.waitingForReview),
            (.inReview, .inProgress),
            (.planned, .inProgress),
            (.inProgress, .inProgress),
            (.completed, .shipped),
            (.rejected, .closed),
            (.unknown("archived"), .inProgress),
        ]
    )
    func bucketsEveryStage(stage: FeedbackThreadRequestStage, section: FeedbackThreadMyRequestsSection) {
        #expect(stage.feedbackThreadMyRequestsSection == section)
    }
}

@Suite("FeedbackThreadFeatureRequest vote updates")
struct FeatureRequestVoteUpdateTests {
    @Test("updatingVote preserves every field, kind included")
    func preservesKind() {
        let bug = FeedbackThreadFeatureRequest(
            id: "FDBK-1",
            title: "Crash on rotate",
            kind: .bug,
            description: "Known issue.",
            votes: 2,
            target: .ios,
            status: "In review",
            voted: false,
            updatedAt: "2026-07-21T00:00:00.000Z",
            shippedInVersion: nil
        )
        let updated = bug.updatingVote(voted: true, votes: 3)
        #expect(updated.kind == .bug)
        #expect(updated.voted == true)
        #expect(updated.votes == 3)
        #expect(updated.title == bug.title)
        #expect(updated.status == bug.status)
    }

    @Test("initializer defaults kind to nil for older call sites")
    func kindDefaults() {
        let request = FeedbackThreadFeatureRequest(
            id: "FDBK-2",
            title: "No kind supplied",
            description: "Pre-0.3.6 shape.",
            votes: 0,
            target: .ios,
            status: "Planned",
            voted: false,
            updatedAt: "2026-07-21T00:00:00.000Z",
            shippedInVersion: nil
        )
        #expect(request.kind == nil)
    }
}
