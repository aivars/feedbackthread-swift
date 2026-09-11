#if os(iOS) && canImport(SwiftUI)
import SwiftUI

public struct FeedbackThreadMessagesList: View {
    @ObservedObject private var conversations: FeedbackThreadConversations
    public init(conversations: FeedbackThreadConversations) { self.conversations = conversations }
    public var body: some View {
        List {
            ForEach(conversations.inbox) { thread in
                NavigationLink {
                    FeedbackThreadConversationView(conversations: conversations, feedbackId: thread.feedbackId, audience: thread.audience)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(thread.title).font(.headline); Spacer(); if thread.unreadCount > 0 { Text("\(thread.unreadCount)").font(.caption.bold()).foregroundStyle(Color.accentColor).accessibilityLabel("\(thread.unreadCount) unread messages") } }
                        Text(thread.audience == .private ? "Private conversation" : "Public comments").font(.caption).foregroundStyle(.secondary)
                        Text(thread.preview).lineLimit(2)
                    }
                }
            }
            if conversations.inbox.isEmpty { Text("Replies to your feedback will appear here.").foregroundStyle(.secondary) }
            if let error = conversations.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Messages")
        .task { try? await conversations.refresh() }
        .refreshable { try? await conversations.refresh() }
    }
}

/// Attach once to the host app's root, not only to the feedback sheet, so
/// foreground messages can show a banner anywhere in the app.
public extension View {
    func feedbackThreadConversations(_ conversations: FeedbackThreadConversations) -> some View {
        modifier(FeedbackThreadConversationHost(conversations: conversations))
    }
}
private struct FeedbackThreadConversationHost: ViewModifier {
    @ObservedObject var conversations: FeedbackThreadConversations
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .environment(\.feedbackThreadConversations, conversations)
            .task(id: scenePhase) { if scenePhase == .active { await conversations.runLive() } }
            .overlay(alignment: .top) {
                if let banner = conversations.banner, conversations.activeConversation?.id != banner.id {
                    HStack {
                        Button { conversations.presentedConversation = .init(feedbackId: banner.feedbackId, audience: banner.audience); conversations.dismissBanner() } label: {
                            Label("New reply about your feedback", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { conversations.dismissBanner() } label: { Label("Dismiss", systemImage: "xmark") }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                }
            }
            .sheet(item: $conversations.presentedConversation) { route in
                NavigationStack {
                    FeedbackThreadConversationView(conversations: conversations, feedbackId: route.feedbackId, audience: route.audience)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { conversations.presentedConversation = nil } } }
                }
            }
    }
}
#endif
