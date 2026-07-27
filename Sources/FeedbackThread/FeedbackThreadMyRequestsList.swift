#if os(iOS) && canImport(SwiftUI)
import SwiftUI

/// A drop-in "My requests" surface: closes the loop for the end user who
/// submitted feedback through the SDK. Unlike ``FeedbackThreadBoard``
/// (the public board), this always shows the caller's own cards, including
/// ones still waiting for review that never appear anywhere public.
public struct FeedbackThreadMyRequestsList: View {
    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let client: FeedbackThreadClient
    private let externalUserID: String?
    private let onDismiss: (() -> Void)?
    private let onUnreadCountChange: ((Int) -> Void)?

    @AppStorage("com.feedbackthread.sdk.voter-id") private var storedVoterID = ""
    @State private var myRequests: [FeedbackThreadMyRequest] = []
    @State private var loadState: LoadState = .loading

    /// - Parameters:
    ///   - externalUserID: The same stable identity already used for voting
    ///     and submission. When nil, the SDK's persisted anonymous voter ID
    ///     is used - the same one the request board generates - so anonymous
    ///     users see their own requests too. This surface only ever shows
    ///     cards matching this exact identity.
    ///   - onUnreadCountChange: Called after every load/refresh with the
    ///     number of shipped-but-unacknowledged cards, so a host app can
    ///     badge its own menu item without re-implementing the fetch.
    public init(
        client: FeedbackThreadClient,
        externalUserID: String? = nil,
        onDismiss: (() -> Void)? = nil,
        onUnreadCountChange: ((Int) -> Void)? = nil
    ) {
        self.client = client
        self.externalUserID = externalUserID
        self.onDismiss = onDismiss
        self.onUnreadCountChange = onUnreadCountChange
    }

    private var voterID: String {
        let provided = externalUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provided.isEmpty ? storedVoterID : provided
    }

    private func ensureVoterID() {
        guard voterID.isEmpty else { return }
        // Delegates generation to the shared resolver so this is the only
        // place a fallback ID gets minted - the request board and the
        // standalone feedback form resolve through the same helper.
        storedVoterID = FeedbackThreadIdentity.resolve(externalUserID: nil)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("My requests", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onDismiss {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: onDismiss) {
                                Text("Done", bundle: .module)
                            }
                        }
                    }
                }
        }
        .task {
            ensureVoterID()
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading where myRequests.isEmpty:
            ProgressView { Text("Loading your requests…", bundle: .module) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where myRequests.isEmpty:
            MyRequestsMessage(
                title: .feedbackThread("Couldn’t load your requests"),
                // The error's own description: written by the server or by
                // URLSession, already localized (or not) at its source.
                message: .feedbackThreadVerbatim(message),
                systemImage: "wifi.exclamationmark",
                actionTitle: .feedbackThread("Try again"),
                action: { Task { await load() } }
            )
        default:
            List {
                myRequestsSection(title: .feedbackThread("Waiting for review"), items: pendingReviewItems)
                myRequestsSection(title: .feedbackThread("In progress"), items: inProgressItems)
                myRequestsSection(title: .feedbackThread("Shipped"), items: shippedItems)
                myRequestsSection(title: .feedbackThread("Closed"), items: closedItems)
            }
            .listStyle(.insetGrouped)
            .overlay {
                if myRequests.isEmpty {
                    MyRequestsMessage(
                        title: .feedbackThread("No requests yet"),
                        message: .feedbackThread("Anything you submit shows up here, including while it’s waiting for review."),
                        systemImage: "tray"
                    )
                }
            }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func myRequestsSection(
        title: LocalizedStringResource,
        items: [FeedbackThreadMyRequest]
    ) -> some View {
        if !items.isEmpty {
            // `Section(_:content:)` has no bundle parameter, so the header is a
            // Text built from the SDK's own catalog instead.
            Section {
                ForEach(items) { item in
                    MyRequestRow(item: item)
                }
            } header: {
                Text(title)
            }
        }
    }

    private var pendingReviewItems: [FeedbackThreadMyRequest] {
        myRequests.filter { $0.status.feedbackThreadRequestStage.feedbackThreadMyRequestsSection == .waitingForReview }
    }

    private var inProgressItems: [FeedbackThreadMyRequest] {
        myRequests.filter { $0.status.feedbackThreadRequestStage.feedbackThreadMyRequestsSection == .inProgress }
    }

    private var shippedItems: [FeedbackThreadMyRequest] {
        myRequests.filter { $0.status.feedbackThreadRequestStage.feedbackThreadMyRequestsSection == .shipped }
    }

    private var closedItems: [FeedbackThreadMyRequest] {
        myRequests.filter { $0.status.feedbackThreadRequestStage.feedbackThreadMyRequestsSection == .closed }
    }

    @MainActor
    private func load() async {
        if myRequests.isEmpty { loadState = .loading }
        do {
            async let requestsTask = client.myRequests(externalUserID: voterID)
            async let updatesTask = client.myUpdates(externalUserID: voterID)
            let (requests, updates) = try await (requestsTask, updatesTask)
            guard !Task.isCancelled else { return }
            myRequests = requests
            loadState = .loaded
            onUnreadCountChange?(updates.unreadCount)
            // Viewing this list is the acknowledgement: once the caller has
            // seen the Shipped section (rendered from `myRequests`, not from
            // `updates`), mark those shipped cards read so the badge clears.
            // Best-effort - a failure here doesn't affect what's on screen.
            if !updates.updates.isEmpty {
                let ids = updates.updates.map(\.id)
                Task {
                    let remaining = (try? await client.acknowledgeUpdates(ids: ids, externalUserID: voterID))
                        ?? updates.unreadCount
                    onUnreadCountChange?(remaining)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

private struct MyRequestsMessage: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemImage: String
    var actionTitle: LocalizedStringResource?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MyRequestRow: View {
    let item: FeedbackThreadMyRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(item.status.feedbackThreadRequestLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
                if let shippedInVersion = item.shippedInVersion {
                    Label {
                        Text("Shipped in \(shippedInVersion)", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                }
                Spacer()
                Label {
                    // Verbatim: a bare count, nothing to translate.
                    Text(verbatim: "\(item.voteCount)")
                } icon: {
                    Image(systemName: "arrow.up.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status.feedbackThreadRequestStage {
        case .pendingReview: .orange
        case .inReview: .cyan
        case .planned: .purple
        case .inProgress: .blue
        case .completed: .green
        case .rejected: .red
        case .unknown: .secondary
        }
    }
}

private struct FeedbackThreadMyRequestsListPreviews: PreviewProvider {
    static var previews: some View {
        FeedbackThreadMyRequestsList(
            client: FeedbackThreadClient(
                submit: { submission, _ in
                    FeedbackThreadFeedback(
                        id: "FDBK-preview",
                        kind: submission.kind,
                        source: "ios",
                        title: submission.title,
                        excerpt: submission.text,
                        version: "Preview",
                        status: "Submitted",
                        count: 1,
                        note: "",
                        responseDraft: "",
                        responseState: "Not started",
                        createdAt: "2026-07-16T12:00:00.000Z",
                        updatedAt: "2026-07-16T12:00:00.000Z"
                    )
                },
                requests: { _ in [] },
                setVote: { id, voted, _, _ in
                    FeedbackThreadVoteResult(feedbackId: id, votes: 1, voted: voted)
                },
                myRequests: { _ in previewRequests },
                myUpdates: { _ in
                    FeedbackThreadMyUpdatesResult(
                        updates: [
                            FeedbackThreadMyUpdate(
                                id: "FDBK-3",
                                title: "Health integration",
                                shippedVersion: "2.4.0",
                                publishedAt: "2026-07-14T12:00:00.000Z"
                            ),
                        ],
                        unreadCount: 1
                    )
                }
            ),
            externalUserID: "preview-user"
        )
    }

    nonisolated private static let previewRequests = [
        FeedbackThreadMyRequest(
            id: "FDBK-1",
            title: "Breathing reminders",
            status: "Submitted",
            createdAt: "2026-07-17T12:00:00.000Z",
            voteCount: 1,
            shippedInVersion: nil
        ),
        FeedbackThreadMyRequest(
            id: "FDBK-2",
            title: "Training complications",
            status: "Planned",
            createdAt: "2026-07-15T12:00:00.000Z",
            voteCount: 12,
            shippedInVersion: nil
        ),
        FeedbackThreadMyRequest(
            id: "FDBK-3",
            title: "Health integration",
            status: "Released",
            createdAt: "2026-07-14T12:00:00.000Z",
            voteCount: 9,
            shippedInVersion: "2.4.0"
        ),
    ]
}
#endif
