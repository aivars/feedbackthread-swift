# Changelog

## Unreleased

The drop-in views are localized, and ship in English and Italian.

- Every user-facing string now lives in a String Catalog
  (`Sources/FeedbackThread/Resources/Localizable.xcstrings`, 50 keys) resolved
  against the SDK's own bundle, so the board, the feedback form, and My Requests
  follow the device's language. Adding a language is a pull request against that
  one file — a test fails on any key left untranslated, or on a translation whose
  format specifiers drift from the English.
- **No API change.** `FeedbackThreadFeedbackKind.title` and
  `FeedbackThreadRequestTarget.title` are untouched English `String`s; the views
  moved to internal localized accessors alongside them.
- The board's empty state is five whole sentences, one per filter, instead of
  interpolating a lowercased status name into `"No … requests"` — a construction
  no language other than English can inflect correctly. The votes accessibility
  value gained a proper plural.
- Wire strings are deliberately untouched: request statuses on the API
  (`"Submitted"`, `"In review"`, `"Ready to release"`, …), enum raw values, URL
  paths, and headers stay exactly as they were, even where a display string reads
  identically. Server messages and unrecognized statuses are still passed through
  verbatim, and `FeedbackThreadError.invalidConfiguration` stays English — it
  addresses the integrator, not the end user.

## 0.4.1

- Bundles a privacy manifest that declares the SDK's app-local `UserDefaults`
  access for its anonymous voter identity.

## 0.4.0

**Breaking**: `FeedbackThreadFeatureRequestList` is now `FeedbackThreadBoard` — the name finally matches what it is: the complete drop-in surface (vote-sorted requests and bugs, Suggest-a-feature submission, My Requests with unread badge). No deprecation alias; update call sites with a find-and-replace. The standalone form and My Requests views are unchanged and documented under Advanced for contextual placements.


## 0.3.8

- Fixes the remaining 0.3.6-era compile break (vote-update path missing the `kind` argument) — and the subtler runtime cousin: on toolchains that tolerated it, voting reconstructed the request without its kind, silently dropping the Bug tag. `FeedbackThreadFeatureRequest` now has an explicit public initializer with `kind` defaulting to nil (immune to memberwise-synthesis differences between Swift toolchains) and a `updatingVote(voted:votes:)` helper that preserves every field, pinned by tests.


## 0.3.7

- Fixes 0.3.6 failing to compile in consumer apps: three preview fixtures were missing the new `kind` argument (one now previews the Bug tag). The release pipeline gained a mandatory clean iOS-simulator build so a macOS-only `swift test` pass can never ship iOS-gated breakage again. Thanks to the integration report that caught it.


## 0.3.6

One entry point, and bugs join the board.

- The board is now the complete integration: My Requests lives behind a person icon in its top bar with an automatic unread-shipped badge (the board checks quietly on load), and submission was already the bottom button. Hosts need exactly one view; the standalone views remain available.
- Accepted public bugs now share the whole board process: they appear alongside feature requests with a red "Bug" tag, are votable ("affects me too"), and get shipped badges. Nothing becomes public without your moderation, same as requests.


## 0.3.5

- Board redesign for reachability: "Suggest a feature" is now a full-width button pinned at the bottom (thumb zone) instead of a toolbar "+", and status filters are an always-visible chip row with counts instead of a title menu.


## 0.3.4

- The feedback form no longer offers "Review" as a submission type — review-kind cards come from App Store / Google Play ingestion, not in-app submission. Custom UI can use `FeedbackThreadFeedbackKind.submittableCases`.


## 0.3.3

One-line integration.

- `FeedbackThreadClient(projectKey:)` — non-throwing convenience initializer; the hosted API URL and platform source are now defaults on `FeedbackThreadConfiguration` (source auto-detects watchOS/iOS at compile time).
- The drop-in feedback form attaches the host app's version automatically (`CFBundleShortVersionString (CFBundleVersion)`); pass `appVersion` only to override. `FeedbackThreadAppVersion.current` is public for custom UI.


## 0.3.2

- One shared identity everywhere: the standalone feedback form now submits with the same persisted anonymous voter ID the board and My Requests use, so anonymous submissions appear in My Requests and receive shipped updates. `FeedbackThreadIdentity.resolve(externalUserID:)` is public so host apps can badge with `myUpdates` at launch — signed-in or not.
- My Requests adds a "Closed" section for rejected items and folds unknown statuses into "In progress" — no more silently blank screens.
- Switching the feedback type resets the retry idempotency key, like editing the text already did.


## 0.3.1

- `FeedbackThreadMyRequestsList` no longer requires `externalUserID`: when omitted it reuses the SDK's persisted anonymous voter ID (the same one the request board generates), so anonymous users — the default — can see their own requests. This matches the Android behavior.

## 0.3.0

Close the loop for end users, and harden the drop-in surfaces.

- **`FeedbackThreadMyRequestsList`** — new drop-in view showing the current user their own requests: pending ones under "Waiting for review", everything in progress, and shipped items with version badges. Auto-acknowledges shipped items and reports an unread count so the host app can badge its own menu.
- `myRequests()`, `myUpdates()`, `acknowledgeUpdates(ids:)` on `FeedbackThreadClient`.
- `customerTierProvider` on the feedback form and request board — the paying/free signal now works with the drop-in UI, read at submit/vote time.
- Retried submissions reuse their idempotency key until they succeed or the content changes, so an uncertain network failure can never create a duplicate.
- Unknown future statuses render instead of hiding requests from the board.
- Vote failures now surface an inline error in the board and detail views.
- Plain-HTTP base URLs are rejected unless the host is loopback.
- Boards arrive most-voted-first (server-side ordering change).

## 0.2.1

Initial public release.

- `FeedbackThreadClient` — async/await client for submissions, the moderated request feed, and voting, with idempotent retries, configurable timeouts, and base-URL validation.
- `FeedbackThreadFeatureRequestList` — SwiftUI feature-request board with voting, status filters, detail views, and **Shipped in x.y.z** badges on released requests.
- `FeedbackThreadFeedbackForm` — SwiftUI bug-report and feature-request form.
- `customerTier` — optional paying/free/custom signal on submissions and votes for revenue-aware prioritization.
- Anonymous voter identity stored on-device; no personal data collected.
