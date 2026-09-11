import Foundation

public struct FeedbackThreadCustomerSession: Codable, Equatable, Sendable {
    public let customerId: String
    public let externalUserId: String
    public let token: String
}
public enum FeedbackThreadConversationAudience: String, Codable, Sendable { case `private`, `public` }
public struct FeedbackThreadConversationSummary: Decodable, Identifiable, Sendable {
    public let id: String
    public let feedbackId: String
    public let title: String
    public let audience: FeedbackThreadConversationAudience
    public let status: String
    public let preview: String
    public let unreadCount: Int
    public let updatedAt: String
}
public struct FeedbackThreadConversationMessage: Decodable, Identifiable, Sendable {
    public let id: String
    public let seq: Int
    public let body: String
    public let authorRole: String
    public let mine: Bool
    public let createdAt: String
    public let deletedAt: String?
}
public struct FeedbackThreadConversationHistory: Decodable, Sendable {
    public struct Thread: Decodable, Sendable {
        public let id: String
        public let audience: FeedbackThreadConversationAudience
        public let status: String
    }
    public let thread: Thread
    public let messages: [FeedbackThreadConversationMessage]
    public let unreadCount: Int
    public let otherReadSeq: Int?
    public let following: Bool
    public let hasMore: Bool
    public let nextBefore: Int?
}
public struct FeedbackThreadConversationInbox: Decodable, Sendable {
    public let conversations: [FeedbackThreadConversationSummary]
    public let unreadCount: Int
}
public struct FeedbackThreadConversationRoute: Identifiable, Equatable, Sendable {
    public let feedbackId: String
    public let audience: FeedbackThreadConversationAudience
    public var id: String { "\(feedbackId):\(audience.rawValue)" }
    public init(feedbackId: String, audience: FeedbackThreadConversationAudience) {
        self.feedbackId = feedbackId; self.audience = audience
    }
    /// Pass only the `feedbackThread` dictionary from the host app's push payload.
    public init?(notification: [AnyHashable: Any]) {
        guard let id = notification["feedbackId"] as? String,
              let raw = notification["audience"] as? String,
              let audience = FeedbackThreadConversationAudience(rawValue: raw), !id.isEmpty else { return nil }
        self.init(feedbackId: id, audience: audience)
    }
}
