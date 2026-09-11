#if os(iOS) && canImport(SwiftUI)
import SwiftUI

private struct FeedbackThreadConversationsKey: EnvironmentKey {
    static let defaultValue: FeedbackThreadConversations? = nil
}
extension EnvironmentValues {
    var feedbackThreadConversations: FeedbackThreadConversations? {
        get { self[FeedbackThreadConversationsKey.self] }
        set { self[FeedbackThreadConversationsKey.self] = newValue }
    }
}
/// Observes remote capability changes even when the board's other state is unchanged.
struct FeedbackThreadCommentsLink: View {
    @ObservedObject var conversations: FeedbackThreadConversations
    let feedbackId: String
    var body: some View {
        if conversations.publicCommentsEnabled {
            NavigationLink("Comments") {
                FeedbackThreadConversationView(conversations: conversations, feedbackId: feedbackId, audience: .public)
            }
        }
    }
}
struct FeedbackThreadMessagesLink: View {
    @ObservedObject var conversations: FeedbackThreadConversations
    var body: some View {
        NavigationLink { FeedbackThreadMessagesList(conversations: conversations) } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .overlay(alignment: .topTrailing) {
                    if conversations.unreadCount > 0 {
                        Text(verbatim: conversations.unreadCount > 99 ? "99+" : "\(conversations.unreadCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.red))
                            .frame(minWidth: 14, minHeight: 14)
                            .offset(x: 9, y: -9)
                    }
                }
                .accessibilityLabel(conversations.unreadCount > 0 ? "Messages (\(conversations.unreadCount))" : "Messages")
        }
    }
}
#endif
