import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FeedbackThread

@Suite("FeedbackThreadClient", .serialized)
struct FeedbackThreadClientTests {
    @Test("Offers feature requests, bug reports, and reviews for SDK submission")
    func exposesAppFeedbackKinds() {
        #expect(FeedbackThreadFeedbackKind.allCases == [.request, .bug, .review])
    }

    @Test("Submits the documented payload and idempotency key")
    func submitsFeedback() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/feedback")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "stable-request-id")

            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["kind"] == "Requests")
            #expect(json["source"] == "ios")
            #expect(json["title"] == "Schedule by weekday")
            #expect(json["text"] == "Please add weekday schedules.")
            #expect(json["appVersion"] == "1.2 (34)")
            #expect(json["externalUserId"] == "user-123")

            return try response(
                statusCode: 201,
                json: [
                    "feedback": sampleFeedback(),
                ]
            )
        }

        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let feedback = try await client.submit(
            FeedbackThreadFeedbackSubmission(
                kind: .request,
                title: "Schedule by weekday",
                text: "Please add weekday schedules.",
                appVersion: "1.2 (34)",
                externalUserID: "user-123"
            ),
            idempotencyKey: "stable-request-id"
        )

        #expect(feedback.id == "FDBK-test")
        #expect(feedback.kind == .request)
        #expect(feedback.status == "Submitted")
    }

    @Test("Surfaces the server error message")
    func surfacesServerError() async throws {
        let recorder = RequestRecorder { _ in
            try response(
                statusCode: 404,
                json: [
                    "error": [
                        "code": "not_found",
                        "message": "Project was not found.",
                    ],
                ]
            )
        }

        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "wrong-key",
                source: "ios"
            ),
            session: recorder.session
        )

        do {
            _ = try await client.submit(
                FeedbackThreadFeedbackSubmission(kind: .bug, title: "Crash", text: "It crashed.")
            )
            Issue.record("Expected a server error")
        } catch let error as FeedbackThreadError {
            #expect(error == .server(statusCode: 404, message: "Project was not found."))
        }
    }

    @Test("Loads the iOS request feed and includes the voter identity")
    func loadsRequests() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/requests?platform=ios")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "user-123")
            return try response(
                statusCode: 200,
                json: ["requests": [sampleRequest()]]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let requests = try await client.requests(externalUserID: "user-123")
        let request = try #require(requests.first)
        #expect(request.id == "FDBK-request")
        #expect(request.target == .watchOS)
        #expect(request.status == "Planned")
        #expect(request.voted)
        #expect(request.shippedInVersion == nil)
    }

    @Test("Decodes shippedInVersion when the request feed reports a published release")
    func decodesShippedInVersion() async throws {
        let recorder = RequestRecorder { _ in
            try response(
                statusCode: 200,
                json: ["requests": [sampleRequest(shippedInVersion: "2.4.0")]]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let requests = try await client.requests(externalUserID: "user-123")
        let request = try #require(requests.first)
        #expect(request.shippedInVersion == "2.4.0")
    }

    @Test("Decodes a null shippedInVersion as nil")
    func decodesNullShippedInVersion() async throws {
        let recorder = RequestRecorder { _ in
            try response(
                statusCode: 200,
                json: ["requests": [sampleRequest(shippedInVersion: NSNull())]]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let requests = try await client.requests(externalUserID: "user-123")
        let request = try #require(requests.first)
        #expect(request.shippedInVersion == nil)
    }

    @Test("Encodes customerTier on submission when provided, omits it otherwise")
    func submissionEncodesCustomerTier() async throws {
        let recorder = RequestRecorder { request in
            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["customerTier"] == "paying")
            return try response(statusCode: 201, json: ["feedback": sampleFeedback()])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        _ = try await client.submit(
            FeedbackThreadFeedbackSubmission(
                kind: .bug,
                title: "Crash",
                text: "It crashed.",
                customerTier: .paying
            )
        )

        let omittingRecorder = RequestRecorder { request in
            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["customerTier"] == nil)
            return try response(statusCode: 201, json: ["feedback": sampleFeedback()])
        }
        let omittingClient = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: omittingRecorder.session
        )

        _ = try await omittingClient.submit(
            FeedbackThreadFeedbackSubmission(kind: .bug, title: "Crash", text: "It crashed.")
        )
    }

    @Test("Encodes a custom customerTier by its raw label")
    func submissionEncodesCustomCustomerTier() async throws {
        let recorder = RequestRecorder { request in
            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["customerTier"] == "enterprise")
            return try response(statusCode: 201, json: ["feedback": sampleFeedback()])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        _ = try await client.submit(
            FeedbackThreadFeedbackSubmission(
                kind: .bug,
                title: "Crash",
                text: "It crashed.",
                customerTier: .custom("enterprise")
            )
        )
    }

    @Test("Carries customerTier in the vote body when provided")
    func voteEncodesCustomerTier() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["customerTier"] == "free")
            return try response(
                statusCode: 200,
                json: [
                    "feedbackId": "FDBK-request",
                    "votes": 13,
                    "voted": true,
                ]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        _ = try await client.setVote(
            for: "FDBK-request",
            voted: true,
            externalUserID: "user-123",
            customerTier: .free
        )
    }

    @Test("Votes and removes votes using the iOS platform context")
    func changesVote() async throws {
        let voteRecorder = RequestRecorder { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/requests/FDBK-request/vote?platform=ios")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "user-123")
            return try response(
                statusCode: 200,
                json: [
                    "feedbackId": "FDBK-request",
                    "votes": 13,
                    "voted": true,
                ]
            )
        }
        let voteClient = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: voteRecorder.session
        )

        let voted = try await voteClient.setVote(
            for: "FDBK-request",
            voted: true,
            externalUserID: "user-123"
        )
        #expect(voted.voted)
        #expect(voted.votes == 13)

        let removeRecorder = RequestRecorder { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/requests/FDBK-request/vote?platform=ios")
            return try response(
                statusCode: 200,
                json: [
                    "feedbackId": "FDBK-request",
                    "votes": 12,
                    "voted": false,
                ]
            )
        }
        let removeClient = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: removeRecorder.session
        )
        let removed = try await removeClient.setVote(
            for: "FDBK-request",
            voted: false,
            externalUserID: "user-123"
        )
        #expect(!removed.voted)
        #expect(removed.votes == 12)
    }

    @Test("Loads my requests, including a private Submitted one, with the voter identity header")
    func loadsMyRequests() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/my/requests")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "user-123")
            return try response(
                statusCode: 200,
                json: ["requests": [sampleMyRequest(), sampleMyRequest(id: "FDBK-pending", status: "Submitted", shippedInVersion: NSNull())]]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let myRequests = try await client.myRequests(externalUserID: "user-123")
        #expect(myRequests.count == 2)
        let pending = try #require(myRequests.first { $0.id == "FDBK-pending" })
        #expect(pending.status == "Submitted")
        #expect(pending.status.feedbackThreadRequestStage == .pendingReview)
        #expect(pending.shippedInVersion == nil)
    }

    @Test("Rejects loading my requests without a stable user ID")
    func rejectsMyRequestsWithoutIdentity() async throws {
        let recorder = RequestRecorder { _ in
            Issue.record("A request should not be sent without an identity")
            return try response(statusCode: 500, json: [:])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        do {
            _ = try await client.myRequests(externalUserID: "   ")
            Issue.record("Expected an invalid configuration error")
        } catch let error as FeedbackThreadError {
            #expect(error == .invalidConfiguration("A stable user ID is required for my requests."))
        }
    }

    @Test("Loads my updates and their unread count")
    func loadsMyUpdates() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/my/updates")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "user-123")
            return try response(
                statusCode: 200,
                json: [
                    "updates": [
                        [
                            "id": "FDBK-shipped",
                            "title": "Health integration",
                            "shippedVersion": "2.4.0",
                            "publishedAt": "2026-07-16T12:00:00.000Z",
                        ],
                    ],
                    "unreadCount": 1,
                ]
            )
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let result = try await client.myUpdates(externalUserID: "user-123")
        #expect(result.unreadCount == 1)
        let update = try #require(result.updates.first)
        #expect(update.id == "FDBK-shipped")
        #expect(update.shippedVersion == "2.4.0")
    }

    @Test("Acknowledges updates and returns the fresh unread count")
    func acknowledgesUpdates() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://example.com/v1/projects/project-key/my/updates/ack")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "user-123")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try requestBody(from: request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
            #expect(json["feedbackIds"] == ["FDBK-shipped"])

            return try response(statusCode: 200, json: ["unreadCount": 0])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        let unreadCount = try await client.acknowledgeUpdates(ids: ["FDBK-shipped"], externalUserID: "user-123")
        #expect(unreadCount == 0)
    }

    @Test("Rejects acknowledging updates with no ids")
    func rejectsAcknowledgingWithNoIDs() async throws {
        let recorder = RequestRecorder { _ in
            Issue.record("A request should not be sent with no ids")
            return try response(statusCode: 500, json: [:])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios"
            ),
            session: recorder.session
        )

        do {
            _ = try await client.acknowledgeUpdates(ids: [], externalUserID: "user-123")
            Issue.record("Expected an invalid configuration error")
        } catch let error as FeedbackThreadError {
            #expect(error == .invalidConfiguration("At least one feedback ID is required to acknowledge updates."))
        }
    }

    @Test("Rejects an empty project key before sending")
    func rejectsEmptyProjectKey() async throws {
        let recorder = RequestRecorder { _ in
            Issue.record("A request should not be sent for an invalid configuration")
            return try response(statusCode: 500, json: [:])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "  ",
                source: "ios"
            ),
            session: recorder.session
        )

        do {
            _ = try await client.submit(
                FeedbackThreadFeedbackSubmission(kind: .bug, title: "Crash", text: "It crashed.")
            )
            Issue.record("Expected an invalid configuration error")
        } catch let error as FeedbackThreadError {
            #expect(error == .invalidConfiguration("A FeedbackThread project key is required."))
        }
    }

    @Test("Rejects a non-HTTP(S) base URL scheme at configuration init")
    func rejectsInvalidBaseURLScheme() {
        #expect(throws: FeedbackThreadError.invalidConfiguration("The FeedbackThread base URL must use HTTP or HTTPS.")) {
            _ = try FeedbackThreadConfiguration(
                baseURL: URL(string: "ftp://example.com")!,
                projectKey: "project-key",
                source: "ios"
            )
        }
    }

    @Test("Accepts an HTTPS base URL for any host")
    func acceptsHTTPSForAnyHost() throws {
        let configuration = try FeedbackThreadConfiguration(
            baseURL: URL(string: "https://example.com")!,
            projectKey: "project-key",
            source: "ios"
        )
        #expect(configuration.baseURL.absoluteString == "https://example.com")
    }

    @Test(
        "Accepts a plain HTTP base URL only when it points at a loopback host",
        arguments: ["http://localhost:8787", "http://127.0.0.1:8787", "http://[::1]:8787"]
    )
    func acceptsHTTPForLoopbackHosts(urlString: String) throws {
        let configuration = try FeedbackThreadConfiguration(
            baseURL: URL(string: urlString)!,
            projectKey: "project-key",
            source: "ios"
        )
        #expect(configuration.baseURL.absoluteString == urlString)
    }

    @Test("Rejects a plain HTTP base URL for any non-loopback host")
    func rejectsHTTPForNonLoopbackHosts() {
        #expect(throws: FeedbackThreadError.invalidConfiguration(
            "The FeedbackThread base URL must use HTTPS unless it points at localhost."
        )) {
            _ = try FeedbackThreadConfiguration(
                baseURL: URL(string: "http://example.com")!,
                projectKey: "project-key",
                source: "ios"
            )
        }
    }

    @Test("Defaults the request timeout to 30 seconds")
    func defaultsRequestTimeout() throws {
        let configuration = try FeedbackThreadConfiguration(
            baseURL: URL(string: "https://example.com")!,
            projectKey: "project-key",
            source: "ios"
        )
        #expect(configuration.requestTimeout == 30)
    }

    @Test("Applies the configured request timeout to outgoing requests")
    func appliesConfiguredRequestTimeout() async throws {
        let recorder = RequestRecorder { request in
            #expect(request.timeoutInterval == 5)
            return try response(statusCode: 201, json: ["feedback": sampleFeedback()])
        }
        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: URL(string: "https://example.com")!,
                projectKey: "project-key",
                source: "ios",
                requestTimeout: 5
            ),
            session: recorder.session
        )

        _ = try await client.submit(
            FeedbackThreadFeedbackSubmission(kind: .bug, title: "Crash", text: "It crashed.")
        )
    }

    @Test("Conversation-enabled requests carry the credential and server identity")
    func conversationIdentity() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-Customer") == identity.token)
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == identity.externalUserId)
            return try response(statusCode: 201, json: ["feedback": sampleFeedback()])
        }
        let client = FeedbackThreadClient(configuration: try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key", customerSession: identity), session: recorder.session)
        _ = try await client.submit(.init(kind: .request, title: "Question", text: "Details", externalUserID: "untrusted-id"))
    }

    @MainActor
    @Test("Conversation history uses the scoped API without marking messages read")
    func conversationHistory() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/projects/project-key/chat/threads/FDBK-1/private")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-Customer") == identity.token)
            return try response(statusCode: 200, json: ["thread": ["id": "FDBK-1:private", "audience": "private", "status": "waiting"], "messages": [], "unreadCount": 1, "following": true, "hasMore": false])
        }
        let configuration = try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key", customerSession: identity)
        let chat = FeedbackThreadConversations(configuration: configuration, session: recorder.session)
        let history = try await chat.history(feedbackId: "FDBK-1", audience: .private)
        #expect(history.unreadCount == 1)
    }

    @Test("Push routing rejects malformed payloads and preserves the private audience")
    func conversationRouting() {
        #expect(FeedbackThreadConversationRoute(notification: ["feedbackId": "FDBK-1", "audience": "private"]) == .init(feedbackId: "FDBK-1", audience: .private))
        #expect(FeedbackThreadConversationRoute(notification: ["feedbackId": "FDBK-1", "audience": "internal"]) == nil)
        #expect(FeedbackThreadConversationRoute(notification: ["feedbackId": "", "audience": "public"]) == nil)
    }

    @MainActor
    @Test("Conversation adoption preserves the existing client identity and request history")
    func conversationAdoptionCompatibility() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            let authenticated = request.value(forHTTPHeaderField: "X-FeedbackThread-Customer") != nil
            if !authenticated { #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-User") == "legacy-user") }
            if request.url?.path.hasSuffix("/my/requests") == true {
                var row = sampleMyRequest(id: authenticated ? "new-request" : "legacy-request")
                row["conversationAvailable"] = authenticated
                return try response(statusCode: 200, json: ["requests": [row]])
            }
            return try response(statusCode: 200, json: ["updates": [["id": authenticated ? "new-request" : "legacy-request", "title": "Shipped", "shippedVersion": "2", "publishedAt": "2026-09-11"]], "unreadCount": 1])
        }
        let config = try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key")
        let existing = FeedbackThreadClient(configuration: config, session: recorder.session)
        var chatConfig = config; chatConfig.customerSession = identity
        let chat = FeedbackThreadConversations(configuration: chatConfig, session: recorder.session)
        let merged = try await chat.myRequests(including: existing, externalUserID: "legacy-user")
        #expect(Set(merged.map(\.id)) == ["legacy-request", "new-request"])
        #expect(merged.first { $0.id == "legacy-request" }?.conversationAvailable == false)
        #expect(merged.first { $0.id == "new-request" }?.conversationAvailable == true)
        #expect(try await chat.myUpdates(including: existing, externalUserID: "legacy-user").unreadCount == 2)
        #expect(try await existing.myRequests(externalUserID: "legacy-user").map(\.id) == ["legacy-request"])
        let adopted = try FeedbackThreadConversations(client: existing)
        #expect(adopted.matches(existing))
        #expect(adopted.notificationsEnabled && adopted.privateRepliesEnabled)
        #expect(!adopted.publicCommentsEnabled)
        #expect(!adopted.matches(FeedbackThreadClient(projectKey: "another-project")))
    }

    @MainActor
    @Test("Remote settings hide comments and remove stale public inbox entries without disabling replies")
    func remoteConversationSettings() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            if request.url?.path.hasSuffix("/settings") == true {
                return try response(statusCode: 200, json: ["publicCommentsEnabled": false, "privateRepliesEnabled": true, "notificationsEnabled": true])
            }
            return try response(statusCode: 200, json: ["conversations": [], "unreadCount": 0])
        }
        let config = try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key", customerSession: identity)
        let chat = FeedbackThreadConversations(configuration: config, session: recorder.session)
        chat.presentedConversation = .init(feedbackId: "public", audience: .public)
        try await chat.refresh()
        #expect(chat.settingsLoaded && !chat.publicCommentsEnabled)
        #expect(chat.presentedConversation == nil)
        #expect(chat.notificationsEnabled && chat.privateRepliesEnabled)
        #expect(chat.handleNotification(["feedbackThread": ["feedbackId": "private", "audience": "private"]]))
        #expect(chat.presentedConversation?.audience == .private)
        #expect(!chat.handleNotification(["unrelated": "notification"]))
    }

    @MainActor
    @Test("Logout revokes the guest and permanently closes that conversation object")
    func conversationLogout() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "X-FeedbackThread-Customer") == identity.token)
            return try response(statusCode: 200, json: ["ok": true])
        }
        let configuration = try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key", customerSession: identity)
        let chat = FeedbackThreadConversations(configuration: configuration, accountScope: UUID().uuidString, session: recorder.session)
        try await chat.logout()
        do { _ = try await chat.prepare(); Issue.record("A logged-out object created a new guest") }
        catch is CancellationError { }
        #expect(chat.inbox.isEmpty && chat.unreadCount == 0)
        #expect(!chat.handleNotification(["feedbackThread": ["feedbackId": "FDBK-1", "audience": "private"]]))
    }

    @MainActor
    @Test("A durable send stays successful when the follow-up refresh fails")
    func conversationSendRefreshFailure() async throws {
        let identity = FeedbackThreadCustomerSession(customerId: "customer", externalUserId: "ft-guest:customer", token: "test-customer-credential")
        let recorder = RequestRecorder { request in
            if request.httpMethod == "POST" { return try response(statusCode: 201, json: ["id": "message-id"]) }
            return try response(statusCode: 503, json: ["error": ["message": "Temporarily unavailable"]])
        }
        let configuration = try FeedbackThreadConfiguration(baseURL: URL(string: "https://example.com")!, projectKey: "project-key", customerSession: identity)
        let chat = FeedbackThreadConversations(configuration: configuration, session: recorder.session)
        try await chat.send("A reply", feedbackId: "FDBK-1", audience: .private, clientId: "stable-client-id")
        #expect(chat.errorMessage != nil)
    }

    @Test("Submits through the live staging service when configured")
    func liveSubmission() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let baseURLString = environment["FEEDBACKTHREAD_LIVE_BASE_URL"],
            let baseURL = URL(string: baseURLString),
            let projectKey = environment["FEEDBACKTHREAD_LIVE_PROJECT_KEY"]
        else {
            return
        }

        let client = FeedbackThreadClient(
            configuration: try FeedbackThreadConfiguration(
                baseURL: baseURL,
                projectKey: projectKey,
                source: "ios"
            )
        )
        let idempotencyKey = "swift-live-\(UUID().uuidString)"
        let feedback = try await client.submit(
            FeedbackThreadFeedbackSubmission(
                kind: .bug,
                title: "Swift SDK live integration test",
                text: "Created by the FeedbackThread Swift package integration test.",
                appVersion: "FeedbackThread SDK alpha"
            ),
            idempotencyKey: idempotencyKey
        )

        #expect(feedback.source == "ios")
        #expect(feedback.title == "Swift SDK live integration test")
        #expect(feedback.status == "Submitted")

        let requests = try await client.requests(externalUserID: "swift-live-reader")
        #expect(!requests.isEmpty)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    let session: URLSession

    init(handler: @escaping Handler) {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: RequestRecorder.Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: FeedbackThreadError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func sampleFeedback() -> [String: Any] {
    [
        "id": "FDBK-test",
        "kind": "Requests",
        "source": "ios",
        "title": "Schedule by weekday",
        "excerpt": "Please add weekday schedules.",
        "version": "1.2 (34)",
        "status": "Submitted",
        "count": 1,
        "note": "",
        "responseDraft": "",
        "responseState": "Not started",
        "createdAt": "2026-07-16T12:00:00.000Z",
        "updatedAt": "2026-07-16T12:00:00.000Z",
    ]
}

private func sampleRequest(shippedInVersion: Any = NSNull()) -> [String: Any] {
    [
        "id": "FDBK-request",
        "title": "Training complications",
        "description": "Show the next practice on my watch face.",
        "votes": 12,
        "target": "watchos",
        "status": "Planned",
        "voted": true,
        "updatedAt": "2026-07-16T12:00:00.000Z",
        "shippedInVersion": shippedInVersion,
    ]
}

private func sampleMyRequest(
    id: String = "FDBK-my-request",
    status: String = "Planned",
    shippedInVersion: Any = NSNull()
) -> [String: Any] {
    [
        "id": id,
        "title": "Training complications",
        "status": status,
        "createdAt": "2026-07-16T12:00:00.000Z",
        "voteCount": 3,
        "shippedInVersion": shippedInVersion,
    ]
}

private func response(statusCode: Int, json: [String: Any]) throws -> (HTTPURLResponse, Data) {
    let url = URL(string: "https://example.com")!
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    return (response, try JSONSerialization.data(withJSONObject: json))
}

private func requestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let bytesRead = stream.read(&buffer, maxLength: buffer.count)
        if bytesRead == 0 { break }
        if bytesRead < 0 {
            throw stream.streamError ?? FeedbackThreadError.invalidResponse
        }
        body.append(buffer, count: bytesRead)
    }
    return body
}
