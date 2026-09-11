import Foundation

/// Server-owned capabilities. Only public comments are optional.
public struct FeedbackThreadConversationSettings: Decodable, Equatable, Sendable {
    public let publicCommentsEnabled: Bool
    public let privateRepliesEnabled: Bool
    public let notificationsEnabled: Bool
}
