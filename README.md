# FeedbackThread Swift SDK

![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%C2%B7%20macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/swift-6.0-orange)
![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

Native in-app feedback for iOS: a drop-in feature-request board with voting, a feedback form, and automatic **"Shipped in x.y.z"** badges — all wired to your [FeedbackThread](https://feedbackthread.com) dashboard, roadmap, and AI-agent workflow.

- 🗳️ **Feature-request board** — moderated public requests with voting, status filters, and full-text detail views
- ✍️ **Feedback form** — bug reports and feature requests straight into your triage inbox
- 🚀 **Close the loop** — requests attached to a published release automatically show a *Shipped in x.y.z* badge to the people who asked
- 💎 **Paying-customer signal** — optionally tag submissions and votes with your paywall state so you can prioritize by revenue
- 🔒 **Privacy-first** — no email or name is required; you control whether to pass an external user identifier; anonymous voter IDs stay on-device
- 🪶 **Zero dependencies** — a small async/await client over `URLSession`, SwiftUI views, nothing else

## What your users see

`FeedbackThreadBoard` follows the system appearance out of the box:

<img src="docs/board-themes.png" alt="FeedbackThreadBoard on iOS in light and dark mode - vote-sorted feature requests with status filters and Shipped badges" width="760">

## Requirements

- iOS 16+ (SwiftUI views) · macOS 13+ (client only)
- Xcode 16 / Swift 6

## Installation

In Xcode: **File → Add Package Dependencies…** and enter

```text
https://github.com/aivars/feedbackthread-swift.git
```

Choose **Up to Next Major Version** from `0.5.0` and add the `FeedbackThread` product.

## Quick start

Grab your project key from the dashboard (**SDK setup**). It's a public, low-privilege identifier — safe to ship in your binary. It can submit feedback, read the moderated request feed, and vote; it cannot touch your private dashboard data.

```swift
import FeedbackThread

let feedbackThread = FeedbackThreadClient(projectKey: "<your-project-key>")
```

Present `FeedbackThreadBoard` and you're done — it's the complete integration:

```swift
.sheet(isPresented: $showFeedbackThread) {
    FeedbackThreadBoard(
        client: feedbackThread,
        externalUserID: signedInUserID   // optional; anonymous ID used otherwise
    )
}
```

One view gives users a vote-sorted board of requests and bugs with status filters (In review · Planned · In progress · Completed) and **Shipped in x.y.z** badges, a **Suggest a feature** button that opens the submission form, and a **My requests** tab with an unread badge that closes the loop on their own cards — all built in.

### Tell FeedbackThread who pays

Pass the same signal you trust for your own paywall — it powers per-request "N paying customers want this" prioritization in the dashboard:

```swift
try await feedbackThread.submit(
    FeedbackThreadFeedbackSubmission(
        kind: .request,
        title: "iCloud sync",
        text: "Sync my data between iPhone and iPad.",
        customerTier: entitlements.isPro ? .paying : .free
    )
)
```

`customerTier` is `.free`, `.paying`, or `.custom("family")` — and omitted entirely when you don't pass it.

## Advanced: standalone surfaces

`FeedbackThreadBoard` is a complete integration on its own, but its pieces are also available individually for contextual placements — e.g. a "Report a bug" row in your settings screen that jumps straight to the form instead of the full board. Each surface below is fully supported as a standalone view.

### Show the feedback form

```swift
.sheet(isPresented: $showFeedback) {
    FeedbackThreadFeedbackForm(
        client: feedbackThread,
    )
}
```

Every submission carries an idempotency key, so a retried request never creates a duplicate.

### Show users their own requests

The board only ever shows moderated, public cards. `FeedbackThreadMyRequestsList` closes the loop for the person who submitted: it always shows their own cards, including ones still waiting for review that never appear anywhere public.

```swift
.sheet(isPresented: $showMyRequests) {
    FeedbackThreadMyRequestsList(
        client: feedbackThread,
        externalUserID: signedInUserID,   // optional; anonymous ID used otherwise
        onDismiss: { showMyRequests = false },
        onUnreadCountChange: { unreadCount in
            // badge your own UI, e.g. a tab item
        }
    )
}
```

It groups cards into **Waiting for review**, **In progress**, and **Shipped**, and auto-acknowledges shipped cards as soon as they're viewed.

`onUnreadCountChange` only fires once the list is opened — too late for a badge that should already be showing at launch. Call `myUpdates(externalUserID:)` yourself on app start or foreground to get `unreadCount` ahead of time:

```swift
.task {
    // Works for anonymous users too: resolve() returns the SDK's
    // persisted on-device ID when you don't pass your own.
    let userID = FeedbackThreadIdentity.resolve(externalUserID: signedInUserID)
    if let result = try? await feedbackThread.myUpdates(externalUserID: userID) {
        badgeCount = result.unreadCount
    }
}
```

The client exposes all three calls directly if you're building custom UI: `myRequests(externalUserID:)`, `myUpdates(externalUserID:)`, and `acknowledgeUpdates(ids:externalUserID:)`.

## Localization

The drop-in views ship in **English and Italian** and follow the device's
language automatically — nothing to configure. A locale the SDK doesn't carry
falls back to English.

All SDK-authored user-facing text lives in one String Catalog,
`Sources/FeedbackThread/Resources/Localizable.xcstrings`. Adding a language is a
pull request against that file and nothing else: open it in Xcode, add the
language, translate every key. A test fails if any key is left untranslated or
if a translation's format specifiers don't match the English ones.

Two things stay untranslated on purpose:

- **Server-supplied text** — request titles and descriptions, error messages
  from the API, and any request status the SDK doesn't recognize are passed
  through exactly as received.
- **Configuration errors** — `FeedbackThreadError.invalidConfiguration` messages
  are addressed to you while you wire the SDK up, not to your users.

`FeedbackThreadFeedbackKind.title` and `FeedbackThreadRequestTarget.title` remain
plain English `String`s, unchanged, for custom UI that already renders them.

### Use the client directly

The SwiftUI views are optional. `FeedbackThreadClient` exposes `submit(_:)`, `requests(externalUserID:)`, and `setVote(for:voted:externalUserID:customerTier:)` if you're building your own UI. Requests time out after a configurable `requestTimeout` (default 30 s).

## How it fits together

The SDK is the in-app half of FeedbackThread: feedback lands in a keyboard-driven triage inbox, becomes cards on your roadmap, ships in tracked releases — and your AI agent can work the whole backlog over [MCP](https://feedbackthread.com). Learn more at [feedbackthread.com](https://feedbackthread.com).

## Contributing

This repository is where the Swift SDK is developed, and pull requests are
merged here. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run the tests
(including the iOS simulator build that `swift test` does not cover) and for the
one invariant worth knowing before you touch status handling.

**Adding a language** is the easiest contribution: every user-facing string
lives in `Sources/FeedbackThread/Resources/Localizable.xcstrings`, and adding a
locale needs no Swift changes at all.

## License

MIT — see [LICENSE](LICENSE).


## Conversations (0.5.0+)

Existing `FeedbackThreadClient`, board, form, request, voting, and release-update
APIs remain supported. Updating the package alone does not change their identity
or require replacing an initializer. Deploy the matching backend migrations
before adopting the new conversation hook. The hosted service supports these endpoints. Existing SDK integrations remain compatible.

Private replies and notifications are enabled for every project. They have no
on/off switch. Public comments are off by default; developers can enable them
under **SDK setup → Replies, comments & notifications**. Turning them off hides
public discussion and blocks new comments on the server, without deleting history
or affecting requests, votes, or private replies. No email is needed.

### Add the conversation hook

Keep the existing client and board. Create one conversation object in your app
model with `try FeedbackThreadConversations(client: feedbackThread)`, then attach
it at the root above your feedback presentation:

```swift
// feedbackThread is your existing HTTP client.
// Retain conversations in your app model or a StateObject; do not recreate it
// during every body evaluation. Handle the throwing initializer at app setup.
let conversations = try FeedbackThreadConversations(client: feedbackThread)

RootView()
    .feedbackThreadConversations(conversations)

// Your existing sheet's content is unchanged:
FeedbackThreadBoard(client: feedbackThread)
```

The root hook supplies the session to SDK views. It owns foreground connection
lifetime, banners, and notification-tap presentation. Forms under that root attach
secure conversation identity to new submissions. The board keeps existing voting
identity, and My requests combines legacy and new submissions without claiming
old requests. Existing release updates and acknowledgements remain available.
Custom handler clients remain unchanged; they require a separate HTTP conversation
client for new features. Different-project clients do not inherit this session.

For custom UI or submissions outside SDK forms, `makeClient()` returns an
authenticated client. Keep the original client for legacy request history. The
standalone conversation and Messages views can also be embedded in navigation.
Observe `unreadCount` or set `onUnreadCountChange` for an app-owned feedback badge.

### Finish push setup

Notifications are enabled by default; provider configuration and user permission
are required for background delivery. The dashboard distinguishes **Setup needed**
(no APNs credentials), **App integration needed** (no registered devices), and
**Configured**. Configured does not prove delivery or a read.

1. Add the app's APNs bundle ID, team ID, key ID, and `.p8` key in the dashboard.
2. Keep your app's notification permission flow. After consent, register with APNs.
3. Forward the device token with `try await conversations.registerDeviceToken(deviceToken)`.
   Retry registration on failure. This must also work for users without an app login.
4. In your existing notification delegate's tap handler, call
   `conversations.handleNotification(response.notification.request.content.userInfo)`
   on the main actor. It returns true for a FeedbackThread payload; false leaves
   unrelated notifications to the host. Always finish the delegate callback.
5. In the foreground, let the SDK render reply banners instead of also showing
   a system alert for the same FeedbackThread notification.

The SDK does not replace notification delegates, automatically prompt for
permission, or add a third-party push dependency. Test foreground, background,
terminated launch/tap, denied permission, and token registration on a real device.
Messages still appear in the conversation when push permission is denied.

### Identity and migration limits

Sessions are server-issued guests stored in Keychain. `accountScope` is a local
namespace, not verified host-account authentication. Cross-device recovery and
host-server identity exchange are not included in this release. For account switching,
replace the conversation object with a scope for that account and revoke/clear
it on logout with `logout()`; handle errors and stop using the old authenticated
client. Legacy history remains governed by the original client/external user ID.

Historical feedback without secure conversation identity remains readable but
has no private reply link. The SDK does not silently claim it. New conversation
UI copy is English pending localization QA. A message marked **Posted** is saved;
**Read** requires the other participant's read cursor, not a push response.
