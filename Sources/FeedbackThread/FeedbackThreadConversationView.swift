#if os(iOS) && canImport(SwiftUI)
import SwiftUI

public struct FeedbackThreadConversationView: View {
    @ObservedObject private var conversations: FeedbackThreadConversations
    private let route: FeedbackThreadConversationRoute
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: FeedbackThreadConversationHistory?
    @State private var earlier: [FeedbackThreadConversationMessage] = []
    @State private var nextBefore: Int?
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false
    @State private var pendingBody = ""
    @State private var pendingId = UUID().uuidString
    @State private var bottomVisible = false
    @State private var readSeq = 0
    @State private var firstLoad = true
    @State private var removeTarget: FeedbackThreadConversationMessage?

    public init(conversations: FeedbackThreadConversations, feedbackId: String, audience: FeedbackThreadConversationAudience) {
        self.conversations = conversations
        self.route = .init(feedbackId: feedbackId, audience: audience)
    }
    public var body: some View {
        Group {
            if route.audience == .public && !conversations.publicCommentsEnabled {
                Text("Public comments are not available for this app. You can still suggest features and vote.").padding()
            } else { conversationContent }
        }
    }
    private var conversationContent: some View {
        VStack(spacing: 0) {
            Text(route.audience == .private ? "Only you and the developer can read this conversation." : "These comments are visible to everyone who can access this request.")
                .font(.footnote).foregroundStyle(.secondary).padding()
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).accessibilityAddTraits(.updatesFrequently) }
            GeometryReader { bounds in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let nextBefore {
                                Button("Load earlier messages") { Task { await loadEarlier(before: nextBefore) } }
                            }
                            ForEach(displayMessages) { message in
                                messageRow(message).id(message.id)
                            }
                            if history?.messages.isEmpty == true { Text("No messages yet. Start the conversation below.").foregroundStyle(.secondary) }
                            Color.clear.frame(height: 1).id("latest")
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key: ConversationEndPosition.self, value: marker.frame(in: .named("conversation")).maxY)
                                })
                        }.padding()
                    }
                    .coordinateSpace(name: "conversation")
                    .onPreferenceChange(ConversationEndPosition.self) { y in bottomVisible = y > 0 && y <= bounds.size.height + 1 }
                    .onChange(of: history?.messages.last?.seq) { _ in
                        if firstLoad || bottomVisible { proxy.scrollTo("latest", anchor: .bottom); firstLoad = false }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if !bottomVisible && history != nil { Button("Jump to latest message") { proxy.scrollTo("latest", anchor: .bottom) }.padding(8).background(.regularMaterial) }
                    }
                }
            }
            HStack(alignment: .bottom) {
                TextField(route.audience == .private ? "Reply to the developer…" : "Write a public comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder).disabled(sending)
                    .onChange(of: draft) { value in if value.count > 4000 { draft = String(value.prefix(4000)) } }
                Button(route.audience == .private ? "Send reply" : "Post comment") { Task { await send() } }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(sending || history == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(route.audience == .private ? "Conversation" : "Comments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let history {
                Button {
                    Task { do { try await conversations.follow(!history.following, feedbackId: route.feedbackId, audience: route.audience); await load() } catch { self.error = error.localizedDescription } }
                } label: {
                    Label(history.following ? "Mute notifications" : "Notify me", systemImage: history.following ? "bell.slash" : "bell")
                }
                .labelStyle(.iconOnly)
            }
        }
        .task(id: conversations.revision) { await load() }
        .task(id: "\(history?.messages.last?.seq ?? 0)-\(bottomVisible)-\(scenePhase == .active)") {
            guard bottomVisible, scenePhase == .active, let seq = history?.messages.last?.seq, seq > readSeq else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                try Task.checkCancellation()
                try await conversations.markRead(seq: seq, feedbackId: route.feedbackId, audience: route.audience)
                readSeq = seq
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
        .onAppear { conversations.activeConversation = route; conversations.dismissBanner() }
        .onDisappear { if conversations.activeConversation == route { conversations.activeConversation = nil } }
        .confirmationDialog("Remove this message?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("Remove message", role: .destructive) {
                guard let message = removeTarget else { return }
                Task { do { try await conversations.remove(messageId: message.id, feedbackId: route.feedbackId, audience: route.audience); await load() } catch { self.error = error.localizedDescription }; removeTarget = nil }
            }
        }
    }
    private func messageRow(_ message: FeedbackThreadConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(message.authorRole == "developer" ? "Developer" : message.mine ? "You" : "App user").font(.caption.bold()); Spacer() }
            Text(message.deletedAt == nil ? message.body : "Message removed").textSelection(.enabled)
            if message.mine {
                Text((history?.otherReadSeq ?? 0) >= message.seq ? "Read" : "Posted").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(message.mine ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu { if message.mine && message.deletedAt == nil { Button("Remove message", role: .destructive) { removeTarget = message } } }
    }
    private var displayMessages: [FeedbackThreadConversationMessage] {
        var items: [String: FeedbackThreadConversationMessage] = [:]
        for message in earlier + (history?.messages ?? []) { items[message.id] = message }
        return items.values.sorted { $0.seq < $1.seq }
    }
    private func load() async {
        do {
            let value = try await conversations.history(feedbackId: route.feedbackId, audience: route.audience)
            try Task.checkCancellation()
            if let first = value.messages.first?.seq, let previous = history?.messages {
                let dropped = previous.filter { $0.seq < first }
                earlier += dropped
            }
            history = value; if earlier.isEmpty { nextBefore = value.nextBefore }; error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func loadEarlier(before: Int) async {
        do {
            let value = try await conversations.history(feedbackId: route.feedbackId, audience: route.audience, before: before)
            earlier = value.messages + earlier; nextBefore = value.nextBefore
        } catch { self.error = error.localizedDescription }
    }
    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !body.isEmpty else { return }
        if pendingBody != body { pendingBody = body; pendingId = UUID().uuidString }
        sending = true
        defer { sending = false }
        do {
            try await conversations.send(body, feedbackId: route.feedbackId, audience: route.audience, clientId: pendingId)
            draft = ""; pendingBody = ""; firstLoad = true; await load()
        } catch { self.error = error.localizedDescription }
    }
}
private struct ConversationEndPosition: PreferenceKey {
    static var defaultValue: CGFloat { .infinity }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
#endif
