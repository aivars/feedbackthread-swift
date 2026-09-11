import Foundation
import Combine

/// Keep one instance for the signed-in host-app account. Run `runLive()` while
/// the host app is foregrounded; its published inbox supplies badges/banners.
@MainActor
public final class FeedbackThreadConversations: ObservableObject {
    @Published public private(set) var publicCommentsEnabled = false
    @Published public private(set) var settingsLoaded = false
    public let notificationsEnabled = true
    public let privateRepliesEnabled = true
    @Published public private(set) var inbox: [FeedbackThreadConversationSummary] = []
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var revision = 0
    @Published public private(set) var isConnected = false
    @Published public private(set) var errorMessage: String?
    @Published public var presentedConversation: FeedbackThreadConversationRoute?
    @Published public private(set) var banner: FeedbackThreadConversationSummary?
    public var activeConversation: FeedbackThreadConversationRoute?
    public var onUnreadCountChange: ((Int) -> Void)?
    private let configuration: FeedbackThreadConfiguration
    private let transport: URLSession
    private let account: String
    private var customer: FeedbackThreadCustomerSession?
    private var pendingSession: Task<FeedbackThreadCustomerSession, Error>?
    private var socket: URLSessionWebSocketTask?
    private var liveRunning = false
    private var generation = 0
    private var refreshRequest = 0

    /// `accountScope` isolates guests on devices used by multiple host-app
    /// accounts. It is a local storage namespace, not proof of server identity.
    public init(configuration: FeedbackThreadConfiguration, accountScope: String = "guest", session: URLSession = .shared) {
        self.configuration = configuration; self.transport = session; self.customer = configuration.customerSession
        self.account = FeedbackThreadConversationCredentials.account(configuration: configuration, scope: accountScope)
    }
    public convenience init(projectKey: String, accountScope: String = "guest") {
        self.init(configuration: try! FeedbackThreadConfiguration(projectKey: projectKey), accountScope: accountScope)
    }
    /// Reuse your existing HTTP client without changing its legacy identity or handlers.
    public convenience init(client: FeedbackThreadClient, accountScope: String = "guest") throws {
        guard let configuration = client.conversationConfiguration, let session = client.conversationSession else {
            throw FeedbackThreadError.invalidConfiguration("Conversations require an HTTP client created with projectKey or configuration. Keep custom-handler clients for existing feedback; create a separate conversation session for new features.")
        }
        self.init(configuration: configuration, accountScope: accountScope, session: session)
    }
    public func prepare() async throws -> FeedbackThreadCustomerSession {
        if let customer { return customer }
        if let pendingSession { return try await pendingSession.value }
        if let saved = try FeedbackThreadConversationCredentials.load(account: account) { customer = saved; return saved }
        let currentGeneration = generation
        let task = Task { @MainActor in
            let request = try makeRequest(path: "/session", method: "POST", data: Data("{}".utf8), authenticated: false)
            let value: FeedbackThreadCustomerSession = try await decode(request)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            try FeedbackThreadConversationCredentials.save(value, account: account)
            customer = value
            return value
        }
        pendingSession = task
        defer { pendingSession = nil }
        return try await task.value
    }
    /// Pass this client to the existing board/form. Submissions are now linked
    /// to the server-issued customer, independent of the form's legacy user ID.
    public func makeClient() async throws -> FeedbackThreadClient {
        let identity = try await prepare()
        var config = configuration; config.customerSession = identity
        return FeedbackThreadClient(configuration: config, session: transport)
    }
    public func history(feedbackId: String, audience: FeedbackThreadConversationAudience, before: Int? = nil) async throws -> FeedbackThreadConversationHistory {
        _ = try await prepare()
        return try await decode(makeRequest(path: threadPath(feedbackId, audience) + (before.map { "?before=\($0)" } ?? "")))
    }
    public func send(_ body: String, feedbackId: String, audience: FeedbackThreadConversationAudience, clientId: String) async throws {
        try await mutate(path: threadPath(feedbackId, audience) + "/messages", method: "POST", values: ["body": body, "clientId": clientId])
        try await refresh()
    }
    public func markRead(seq: Int, feedbackId: String, audience: FeedbackThreadConversationAudience) async throws {
        try await mutate(path: threadPath(feedbackId, audience) + "/read", method: "POST", values: ["seq": seq])
        try await refresh()
    }
    public func follow(_ following: Bool, feedbackId: String, audience: FeedbackThreadConversationAudience) async throws {
        try await mutate(path: threadPath(feedbackId, audience) + "/follow", method: "PUT", values: ["following": following])
    }
    public func remove(messageId: String, feedbackId: String, audience: FeedbackThreadConversationAudience) async throws {
        try await mutate(path: threadPath(feedbackId, audience) + "/messages/\(messageId)", method: "DELETE", values: [:])
        try await refresh()
    }
    public func registerDeviceToken(_ deviceToken: Data) async throws {
        try await mutate(path: "/device", method: "PUT", values: ["token": deviceToken.map { String(format: "%02x", $0) }.joined()])
    }
    public func unregisterDeviceToken(_ deviceToken: Data) async throws {
        try await mutate(path: "/device", method: "DELETE", values: ["token": deviceToken.map { String(format: "%02x", $0) }.joined()])
    }
    /// Stop live updates, revoke this guest session, and clear local credentials.
    /// Do not reuse an old makeClient() result after signing out.
    public func logout() async throws {
        generation += 1; pendingSession?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        customer = try customer ?? FeedbackThreadConversationCredentials.load(account: account)
        let request = customer == nil ? nil : try makeRequest(path: "/session", method: "DELETE", data: Data("{}".utf8))
        try FeedbackThreadConversationCredentials.remove(account: account)
        publicCommentsEnabled = false; settingsLoaded = false
        customer = nil; inbox = []; unreadCount = 0; banner = nil; presentedConversation = nil; activeConversation = nil
        onUnreadCountChange?(0)
        if let request { struct Result: Decodable { let ok: Bool }; let _: Result = try await decode(request) }
    }
    public func refresh() async throws {
        let currentGeneration = generation
        refreshRequest += 1; let requestNumber = refreshRequest
        _ = try await prepare()
        let settings: FeedbackThreadConversationSettings = try await decode(makeRequest(path: "/settings"))
        guard generation == currentGeneration, requestNumber == refreshRequest else { return }
        publicCommentsEnabled = settings.publicCommentsEnabled; settingsLoaded = true
        if !publicCommentsEnabled {
            inbox.removeAll { $0.audience == .public }
            if banner?.audience == .public { banner = nil }
            if presentedConversation?.audience == .public { presentedConversation = nil }
        }
        let data: FeedbackThreadConversationInbox = try await decode(makeRequest(path: "/inbox"))
        guard generation == currentGeneration else { throw CancellationError() }
        guard requestNumber == refreshRequest else { return }
        let old = Dictionary(uniqueKeysWithValues: inbox.map { ($0.id, $0.unreadCount) })
        if revision > 0, let latest = data.conversations.first(where: { $0.unreadCount > (old[$0.id] ?? 0) && $0.id != activeConversation?.id }) { banner = latest }
        inbox = data.conversations; unreadCount = data.unreadCount; revision += 1; onUnreadCountChange?(unreadCount)
    }
    /// Existing requests remain visible; only the credential-scoped result can
    /// grant access to private conversation links. Never claim old submissions.
    public func myRequests(including client: FeedbackThreadClient, externalUserID: String) async throws -> [FeedbackThreadMyRequest] {
        let legacy = try await client.myRequests(externalUserID: externalUserID)
        let authenticated = try await makeClient()
        let current = try await authenticated.myRequests(externalUserID: externalUserID)
        var merged = Dictionary(legacy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in current { merged[item.id] = item }
        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }
    public func myUpdates(including client: FeedbackThreadClient, externalUserID: String) async throws -> FeedbackThreadMyUpdatesResult {
        let legacy = try await client.myUpdates(externalUserID: externalUserID)
        let authenticated = try await makeClient()
        let current = try await authenticated.myUpdates(externalUserID: externalUserID)
        var merged = Dictionary(legacy.updates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in current.updates { merged[item.id] = item }
        let overlap = Set(legacy.updates.map(\.id)).intersection(current.updates.map(\.id)).count
        return .init(updates: merged.values.sorted { $0.publishedAt > $1.publishedAt }, unreadCount: legacy.unreadCount + current.unreadCount - overlap)
    }
    public func acknowledgeUpdates(ids: [String], including client: FeedbackThreadClient, externalUserID: String) async throws -> Int {
        _ = try await client.acknowledgeUpdates(ids: ids, externalUserID: externalUserID)
        let authenticated = try await makeClient()
        _ = try await authenticated.acknowledgeUpdates(ids: ids, externalUserID: externalUserID)
        return try await myUpdates(including: client, externalUserID: externalUserID).unreadCount
    }
    /// Forward notification taps here; false means the host should handle it.
    @discardableResult public func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = userInfo["feedbackThread"] as? [AnyHashable: Any], let route = FeedbackThreadConversationRoute(notification: payload) else { return false }
        if route.audience == .public && settingsLoaded && !publicCommentsEnabled { return true }
        presentedConversation = route
        return true
    }
    func matches(_ client: FeedbackThreadClient) -> Bool {
        guard let other = client.conversationConfiguration else { return false }
        return configuration.baseURL == other.baseURL && configuration.projectKey == other.projectKey
    }
    public func dismissBanner() { banner = nil }
    /// Cancellation closes the socket. The host owns foreground/background
    /// lifecycle; the SDK never asks for notification permission automatically.
    public func runLive() async {
        while liveRunning {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        guard !Task.isCancelled else { return }
        liveRunning = true
        defer { liveRunning = false; isConnected = false; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
        var delay: UInt64 = 1
        let currentGeneration = generation
        while !Task.isCancelled && generation == currentGeneration {
            do {
                try await refresh()
                struct Ticket: Decodable { let path: String }
                let ticket: Ticket = try await decode(makeRequest(path: "/live-ticket", method: "POST", data: Data("{}".utf8)))
                guard var parts = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else { throw FeedbackThreadError.invalidResponse }
                parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = ticket.path; parts.query = nil
                guard let url = parts.url else { throw FeedbackThreadError.invalidResponse }
                let connection = transport.webSocketTask(with: url); socket = connection; connection.resume()
                let heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        try await connection.send(.string("ping"))
                    }
                }
                defer { heartbeat.cancel(); connection.cancel(with: .goingAway, reason: nil) }
                try await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        if case .string(let value) = message, value != "pong" {
                            isConnected = true; delay = 1; errorMessage = nil; try await refresh()
                        }
                    }
                } onCancel: { connection.cancel(with: .goingAway, reason: nil) }
            } catch {
                isConnected = false
                if Task.isCancelled || generation != currentGeneration { return }
                errorMessage = error.localizedDescription
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                delay = min(30, delay * 2)
            }
        }
    }
    private func threadPath(_ id: String, _ audience: FeedbackThreadConversationAudience) -> String {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return "/threads/\(escaped)/\(audience.rawValue)"
    }
    private func mutate(path: String, method: String, values: [String: Any]) async throws {
        _ = try await prepare()
        let request = try makeRequest(path: path, method: method, data: JSONSerialization.data(withJSONObject: values))
        struct Result: Decodable { let ok: Bool?; let id: String? }
        let _: Result = try await decode(request)
    }
    private func makeRequest(path: String, method: String = "GET", data: Data? = nil, authenticated: Bool = true) throws -> URLRequest {
        let endpoint = configuration.baseURL.appendingPathComponent("v1/projects").appendingPathComponent(configuration.projectKey).appendingPathComponent("chat")
        guard let url = URL(string: endpoint.absoluteString + path) else { throw FeedbackThreadError.invalidConfiguration("Invalid conversation URL.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = data; request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { request.setValue(customer?.token, forHTTPHeaderField: "X-FeedbackThread-Customer") }
        return request
    }
    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FeedbackThreadError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? "Could not load the conversation."
            throw FeedbackThreadError.server(statusCode: response.statusCode, message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct ErrorBody: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
