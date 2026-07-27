#if os(iOS) && canImport(SwiftUI)
import SwiftUI

/// A standalone "send feedback" form: usable on its own (e.g. from a Settings
/// screen) without the request board around it. Submissions are tied to the
/// same on-device anonymous ID the board and My Requests use, unless an
/// external ID is supplied - so a submission made from here still shows up
/// in "My requests" and can receive shipped updates.
public struct FeedbackThreadFeedbackForm: View {
    private enum SubmissionPhase: Equatable {
        case editing
        case submitting
        case sent
        case failed(String)
    }

    private struct PendingSubmission: Equatable, Identifiable, Sendable {
        let id: String
        let idempotencyKey: String
        let submission: FeedbackThreadFeedbackSubmission
    }

    @Environment(\.dismiss) private var dismiss

    private let client: FeedbackThreadClient
    private let appVersion: String?
    private let externalUserID: String?
    private let customerTierProvider: (() -> FeedbackThreadCustomerTier?)?
    private let onSubmitted: @MainActor @Sendable (FeedbackThreadFeedback) -> Void

    @State private var kind: FeedbackThreadFeedbackKind = .request
    @State private var title = ""
    @State private var message = ""
    @State private var phase: SubmissionPhase = .editing
    @State private var pendingSubmission: PendingSubmission?
    @State private var resubmissionKey = FeedbackThreadResubmissionKey()

    public init(
        client: FeedbackThreadClient,
        appVersion: String? = nil,
        externalUserID: String? = nil,
        customerTierProvider: (() -> FeedbackThreadCustomerTier?)? = nil,
        onSubmitted: @escaping @MainActor @Sendable (FeedbackThreadFeedback) -> Void = { _ in }
    ) {
        self.client = client
        self.appVersion = appVersion
        self.externalUserID = externalUserID
        self.customerTierProvider = customerTierProvider
        self.onSubmitted = onSubmitted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $kind) {
                        ForEach(FeedbackThreadFeedbackKind.submittableCases) { option in
                            Text(option.localizedTitle).tag(option)
                        }
                    } label: {
                        Text("Feedback type", bundle: .module)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _ in resubmissionKey.contentChanged() }

                    // `TextField(_:text:)` takes a `LocalizedStringKey` that would
                    // resolve against the host app's bundle, so the placeholder is
                    // resolved here and handed over as a plain String.
                    TextField(String(localized: "Short title", bundle: .module), text: $title)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: title) { _ in resubmissionKey.contentChanged() }

                    TextEditor(text: $message)
                        .frame(minHeight: 120)
                        .accessibilityLabel(Text("Feedback details", bundle: .module))
                        .onChange(of: message) { _ in resubmissionKey.contentChanged() }
                } header: {
                    Text("What would you like to share?", bundle: .module)
                }

                if case .failed(let errorMessage) = phase {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if phase == .sent {
                    Section {
                        Label {
                            Text(confirmationMessage)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(.green)

                        Button { dismiss() } label: {
                            Text("Done", bundle: .module)
                        }
                    }
                } else {
                    Section {
                        Button {
                            beginSubmission()
                        } label: {
                            HStack {
                                Spacer()
                                if phase == .submitting {
                                    ProgressView()
                                } else {
                                    Text("Send feedback", bundle: .module)
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canSubmit || phase == .submitting)
                    }
                }
            }
            .navigationTitle(Text("Feedback", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel", bundle: .module)
                    }
                }
            }
            .task(id: pendingSubmission?.id) {
                guard let pendingSubmission else { return }
                await submit(pendingSubmission)
            }
        }
    }

    /// A request is moderated before it reaches the public board, a bug report
    /// isn't - two different promises, so two separate keys rather than one
    /// sentence with a swapped-out clause.
    private var confirmationMessage: LocalizedStringResource {
        kind == .request
            ? .feedbackThread("Request submitted for review.")
            : .feedbackThread("Feedback sent. Thank you!")
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginSubmission() {
        guard canSubmit else { return }
        // Reused across retries of the same content so a network failure followed
        // by tapping Send again can't create a duplicate submission server-side.
        let idempotencyKey = resubmissionKey.beginAttempt()
        // Always resolves to a non-empty identity - the provided external ID,
        // or the same persisted anonymous ID the board and My Requests use -
        // so this submission is never orphaned from "My requests".
        let resolvedUserID = FeedbackThreadIdentity.resolve(externalUserID: externalUserID)
        pendingSubmission = PendingSubmission(
            id: UUID().uuidString,
            idempotencyKey: idempotencyKey,
            submission: FeedbackThreadFeedbackSubmission(
                kind: kind,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: message.trimmingCharacters(in: .whitespacesAndNewlines),
                appVersion: appVersion ?? FeedbackThreadAppVersion.current,
                externalUserID: resolvedUserID,
                customerTier: customerTierProvider?()
            )
        )
        phase = .submitting
    }

    @MainActor
    private func submit(_ pending: PendingSubmission) async {
        do {
            let feedback = try await client.submit(pending.submission, idempotencyKey: pending.idempotencyKey)
            guard !Task.isCancelled else { return }
            phase = .sent
            resubmissionKey.submissionSucceeded()
            onSubmitted(feedback)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct FeedbackThreadFeedbackFormPreviews: PreviewProvider {
    static var previews: some View {
        FeedbackThreadFeedbackForm(
            client: FeedbackThreadClient { submission, _ in
                FeedbackThreadFeedback(
                    id: "FDBK-preview",
                    kind: submission.kind,
                    source: "ios",
                    title: submission.title,
                    excerpt: submission.text,
                    version: submission.appVersion ?? "Preview",
                    status: "Submitted",
                    count: 1,
                    note: "",
                    responseDraft: "",
                    responseState: "Not started",
                    createdAt: "2026-07-16T12:00:00.000Z",
                    updatedAt: "2026-07-16T12:00:00.000Z"
                )
            },
            appVersion: "1.0 (42)"
        )
    }
}
#endif
