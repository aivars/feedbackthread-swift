#if os(iOS) && canImport(SwiftUI)
import SwiftUI

private enum FeatureRequestRoute: Hashable {
    case detail(String)
}

public struct FeedbackThreadBoard: View {
    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private enum ActiveSheet: String, Identifiable {
        case submit
        case myRequests

        var id: String { rawValue }
    }

    private enum RequestFilter: String, CaseIterable, Identifiable {
        case all
        case inReview
        case planned
        case inProgress
        case completed

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .all: .feedbackThread("All")
            case .inReview: .feedbackThread("In review")
            case .planned: .feedbackThread("Planned")
            case .inProgress: .feedbackThread("In progress")
            case .completed: .feedbackThread("Completed")
            }
        }

        /// A whole sentence per filter rather than "No \(title.lowercased())
        /// requests": lowercasing a status name and dropping it into a slot has
        /// no correct translation - other languages inflect the adjective, and
        /// several put it before the noun.
        var emptyStateTitle: LocalizedStringResource {
            switch self {
            case .all: .feedbackThread("No requests")
            case .inReview: .feedbackThread("No requests in review")
            case .planned: .feedbackThread("No planned requests")
            case .inProgress: .feedbackThread("No requests in progress")
            case .completed: .feedbackThread("No completed requests")
            }
        }

        func includes(_ status: String) -> Bool {
            switch self {
            // Unknown statuses are included under "All" rather than dropped, so a
            // status the SDK doesn't recognize yet doesn't silently hide cards.
            case .all: true
            case .inReview: status.feedbackThreadRequestStage == .inReview
            case .planned: status.feedbackThreadRequestStage == .planned
            case .inProgress: status.feedbackThreadRequestStage == .inProgress
            case .completed: status.feedbackThreadRequestStage == .completed
            }
        }
    }

    private let client: FeedbackThreadClient
    private let appVersion: String?
    private let externalUserID: String?
    private let customerTierProvider: (() -> FeedbackThreadCustomerTier?)?
    private let onDismiss: (() -> Void)?

    @AppStorage("com.feedbackthread.sdk.voter-id") private var storedVoterID = ""
    @State private var requests: [FeedbackThreadFeatureRequest] = []
    @State private var loadState: LoadState = .loading
    @State private var votingIDs: Set<String> = []
    @State private var activeSheet: ActiveSheet?
    @State private var selectedFilter: RequestFilter = .all
    @State private var voteErrorMessage: String?
    @State private var unreadCount = 0
    @State private var presentedMyRequestsSheet = false

    public init(
        client: FeedbackThreadClient,
        appVersion: String? = nil,
        externalUserID: String? = nil,
        customerTierProvider: (() -> FeedbackThreadCustomerTier?)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.client = client
        self.appVersion = appVersion
        self.externalUserID = externalUserID
        self.customerTierProvider = customerTierProvider
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChipRow
                content
            }
            .navigationTitle(Text("Feature requests", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FeatureRequestRoute.self, destination: requestDestination)
            .toolbar {
                if let onDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onDismiss) {
                            Text("Done", bundle: .module)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedMyRequestsSheet = true
                        activeSheet = .myRequests
                    } label: {
                        myRequestsToolbarIcon
                    }
                    .accessibilityLabel(Text("My requests", bundle: .module))
                }
            }
            .safeAreaInset(edge: .bottom) {
                addRequestButton
            }
        }
        .task {
            ensureVoterID()
            await load()
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .submit:
                FeedbackThreadFeedbackForm(
                    client: client,
                    appVersion: appVersion,
                    externalUserID: voterID,
                    customerTierProvider: customerTierProvider,
                    onSubmitted: { _ in
                        Task { await load() }
                    }
                )
            case .myRequests:
                FeedbackThreadMyRequestsList(
                    client: client,
                    externalUserID: externalUserID,
                    onDismiss: { activeSheet = nil },
                    onUnreadCountChange: { unreadCount = $0 }
                )
            }
        }
    }

    // iOS16-compatible badge: `.badge()` on toolbar items is iOS17+, so this
    // overlays a small Circle+Text directly on the icon instead.
    private var myRequestsToolbarIcon: some View {
        Image(systemName: "person.crop.circle")
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    // Verbatim: a digit count and an overflow marker, nothing to translate.
                    Text(verbatim: unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.red))
                        .frame(minWidth: 14, minHeight: 14)
                        .offset(x: 9, y: -9)
                }
            }
    }

    private func handleSheetDismiss() {
        guard presentedMyRequestsSheet else { return }
        presentedMyRequestsSheet = false
        Task { await refreshUnreadCount() }
    }

    // Pinned in the thumb zone rather than tucked into the top-trailing
    // toolbar, matching the mobile pattern where the primary action stays
    // reachable with one hand. The bar material keeps list content that
    // scrolls beneath it legible.
    private var addRequestButton: some View {
        Button {
            activeSheet = .submit
        } label: {
            Text("Suggest a feature", bundle: .module)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // Filters are always-visible chips under the nav bar instead of hiding
    // behind a title-menu chevron, so the current status filter and its
    // count are legible at a glance.
    private var filterChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RequestFilter.allCases) { filter in
                    FilterChipButton(
                        title: filter.title,
                        count: requestCount(for: filter),
                        isSelected: selectedFilter == filter,
                        action: { selectedFilter = filter }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading where requests.isEmpty:
            ProgressView { Text("Loading requests…", bundle: .module) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where requests.isEmpty:
            FeatureRequestMessage(
                title: .feedbackThread("Couldn’t load requests"),
                // The error's own description: written by the server or by
                // URLSession, already localized (or not) at its source.
                message: .feedbackThreadVerbatim(message),
                systemImage: "wifi.exclamationmark",
                actionTitle: .feedbackThread("Try again"),
                action: { Task { await load() } }
            )
        default:
            VStack(spacing: 0) {
                if let voteErrorMessage {
                    Label(voteErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                List(filteredRequests) { request in
                    FeatureRequestRow(
                        request: request,
                        isVoting: votingIDs.contains(request.id),
                        onVote: { toggleVote(request) }
                    )
                    .listRowInsets(.init(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                .listStyle(.plain)
                .overlay {
                    if filteredRequests.isEmpty {
                        emptyStateMessage
                    }
                }
                .refreshable { await load() }
            }
        }
    }

    /// Two different empty states: nothing published at all, or nothing left
    /// after the selected filter. Each branch picks whole sentences rather than
    /// assembling one, so every language can phrase them its own way.
    @ViewBuilder
    private var emptyStateMessage: some View {
        if requests.isEmpty {
            FeatureRequestMessage(
                title: .feedbackThread("No feature requests yet"),
                message: .feedbackThread("Be the first to share an idea."),
                systemImage: "lightbulb"
            )
        } else {
            FeatureRequestMessage(
                title: selectedFilter.emptyStateTitle,
                message: .feedbackThread("Choose another status to see more requests."),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var voterID: String {
        let provided = externalUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provided.isEmpty ? storedVoterID : provided
    }

    private var filteredRequests: [FeedbackThreadFeatureRequest] {
        requests.filter { selectedFilter.includes($0.status) }
    }

    private func requestCount(for filter: RequestFilter) -> Int {
        requests.count { filter.includes($0.status) }
    }

    @ViewBuilder
    private func requestDestination(_ route: FeatureRequestRoute) -> some View {
        switch route {
        case .detail(let requestID):
            if let request = requests.first(where: { $0.id == requestID }) {
                FeatureRequestDetail(
                    request: request,
                    isVoting: votingIDs.contains(request.id),
                    errorMessage: voteErrorMessage,
                    onVote: { toggleVote(request) }
                )
            } else {
                FeatureRequestMessage(
                    title: .feedbackThread("Request unavailable"),
                    message: .feedbackThread("This request is no longer available on the public board."),
                    systemImage: "rectangle.slash"
                )
            }
        }
    }

    private func ensureVoterID() {
        guard voterID.isEmpty else { return }
        // Delegates generation to the shared resolver so this is the only
        // place a fallback ID gets minted - the standalone feedback form and
        // My Requests resolve through the same helper.
        storedVoterID = FeedbackThreadIdentity.resolve(externalUserID: nil)
    }

    @MainActor
    private func load() async {
        if requests.isEmpty { loadState = .loading }
        // Fired alongside the request fetch rather than after it, so opening
        // the board doesn't delay the badge any longer than it has to.
        async let unreadCountTask: Void = refreshUnreadCount()
        do {
            let loaded = try await client.requests(externalUserID: voterID)
            guard !Task.isCancelled else { return }
            requests = loaded
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
        await unreadCountTask
    }

    // Best-effort: badging the toolbar icon is a nicety, not something that
    // should ever surface an error or block the board from loading.
    @MainActor
    private func refreshUnreadCount() async {
        guard let result = try? await client.myUpdates(externalUserID: voterID) else { return }
        unreadCount = result.unreadCount
    }

    private func toggleVote(_ request: FeedbackThreadFeatureRequest) {
        guard !votingIDs.contains(request.id) else { return }
        votingIDs.insert(request.id)
        voteErrorMessage = nil
        Task {
            defer { votingIDs.remove(request.id) }
            do {
                let result = try await client.setVote(
                    for: request.id,
                    voted: !request.voted,
                    externalUserID: voterID,
                    customerTier: customerTierProvider?()
                )
                guard let index = requests.firstIndex(where: { $0.id == request.id }) else { return }
                requests[index] = requests[index].updatingVote(voted: result.voted, votes: result.votes)
            } catch {
                // The list only ever applies a vote change once the server confirms
                // it, so there's no optimistic state to roll back here — but the
                // failure still needs to be visible even when the list isn't empty.
                voteErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct FeatureRequestMessage: View {
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

private struct FilterChipButton: View {
    let title: LocalizedStringResource
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // One key for the whole chip rather than gluing the pieces together
            // here, so a language can reorder or re-punctuate the pair.
            Text(.feedbackThread("filter.chip", defaultValue: "\(String(localized: title)) (\(count))"))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct FeatureRequestRow: View {
    let request: FeedbackThreadFeatureRequest
    let isVoting: Bool
    let onVote: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FeatureRequestVoteButton(
                votes: request.votes,
                isVoted: request.voted,
                isVoting: isVoting,
                action: onVote
            )

            NavigationLink(value: FeatureRequestRoute.detail(request.id)) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(request.title)
                            .font(.headline)
                        if let targetTitle = request.target.localizedTitle {
                            Text(targetTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(request.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        if request.kind == .bug {
                            Text("Bug", bundle: .module)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.12), in: Capsule())
                                .foregroundStyle(.red)
                        }
                        FeatureRequestStatusBadge(status: request.status)
                        if let shippedInVersion = request.shippedInVersion {
                            ShippedInVersionBadge(version: shippedInVersion)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
    }
}

private struct FeatureRequestDetail: View {
    let request: FeedbackThreadFeatureRequest
    let isVoting: Bool
    var errorMessage: String?
    let onVote: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(request.title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    FeatureRequestVoteButton(
                        votes: request.votes,
                        isVoted: request.voted,
                        isVoting: isVoting,
                        action: onVote
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            FeatureRequestStatusBadge(status: request.status)
                            if let shippedInVersion = request.shippedInVersion {
                                ShippedInVersionBadge(version: shippedInVersion)
                            }
                        }
                        if let targetTitle = request.target.localizedTitle {
                            Label {
                                Text(targetTitle)
                            } icon: {
                                Image(systemName: "applewatch")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Divider()

                Text(request.description)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .navigationTitle(Text("Request", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeatureRequestStatusBadge: View {
    let status: String

    var body: some View {
        Text(status.feedbackThreadRequestLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch status.feedbackThreadRequestStage {
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

private struct ShippedInVersionBadge: View {
    let version: String

    var body: some View {
        Label {
            Text("Shipped in \(version)", bundle: .module)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.12), in: Capsule())
    }
}

private struct FeatureRequestVoteButton: View {
    let votes: Int
    let isVoted: Bool
    let isVoting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if isVoting {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: isVoted ? "arrow.up.circle.fill" : "arrow.up.circle")
                    }
                }
                .font(.title3.weight(.semibold))
                .frame(height: 24)

                // Verbatim: a bare count, nothing to translate.
                Text(verbatim: "\(votes)")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .frame(minWidth: 52)
            .frame(minHeight: 60)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isVoted ? Color.accentColor : .secondary)
        .disabled(isVoting)
        .accessibilityLabel(Text(voteAccessibilityLabel))
        .accessibilityValue(Text(.feedbackThread("\(votes) votes")))
    }

    /// Two separate keys rather than one with a placeholder: the two states are
    /// different sentences, and several languages inflect the verb differently.
    private var voteAccessibilityLabel: LocalizedStringResource {
        isVoted ? .feedbackThread("Remove vote") : .feedbackThread("Vote")
    }

    private var backgroundColor: Color {
        isVoted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }
}

private struct FeedbackThreadBoardPreviews: PreviewProvider {
    static var previews: some View {
        FeedbackThreadBoard(
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
                requests: { _ in previewRequests },
                setVote: { id, voted, _, _ in
                    FeedbackThreadVoteResult(feedbackId: id, votes: voted ? 35 : 34, voted: voted)
                }
            )
        )
    }

    nonisolated private static let previewRequests = [
        FeedbackThreadFeatureRequest(
            id: "FDBK-1",
            title: "Breathing reminders",
            kind: .request,
            description: "Remind me when it is time to practice.",
            votes: 34,
            target: .ios,
            status: "In progress",
            voted: true,
            updatedAt: "2026-07-16T12:00:00.000Z",
            shippedInVersion: nil
        ),
        FeedbackThreadFeatureRequest(
            id: "FDBK-2",
            title: "Training complications",
            kind: .bug,
            description: "Show the next practice on my watch face.",
            votes: 12,
            target: .watchOS,
            status: "Planned",
            voted: false,
            updatedAt: "2026-07-15T12:00:00.000Z",
            shippedInVersion: nil
        ),
        FeedbackThreadFeatureRequest(
            id: "FDBK-3",
            title: "Health integration",
            kind: .request,
            description: "Include completed breathing sessions in Health.",
            votes: 9,
            target: .ios,
            status: "Released",
            voted: false,
            updatedAt: "2026-07-14T12:00:00.000Z",
            shippedInVersion: "2.4.0"
        ),
    ]
}
#endif
