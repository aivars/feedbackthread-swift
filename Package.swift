// swift-tools-version: 6.0
// Standalone manifest for the published FeedbackThread Swift SDK.
// The monorepo root Package.swift consumes these same sources in place;
// this file exists so `sdk/swift` can be split out (scripts/publish-swift-sdk.sh)
// into the public feedbackthread-swift repository that customers add via SPM
// without pulling the whole product monorepo.

import PackageDescription

let package = Package(
    name: "FeedbackThread",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "FeedbackThread", targets: ["FeedbackThread"]),
    ],
    targets: [
        .target(
            name: "FeedbackThread",
            path: "Sources/FeedbackThread",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "FeedbackThreadTests",
            dependencies: ["FeedbackThread"],
            path: "Tests/FeedbackThreadTests"
        ),
    ]
)
