// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftMarkdown",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Parser and renderer in one target. The parser half is Foundation-only
        // and usable on its own; the SwiftUI half sits on top of it.
        .library(name: "SwiftMarkdown", targets: ["SwiftMarkdown"]),
    ],
    targets: [
        .target(name: "SwiftMarkdown"),
        .testTarget(name: "SwiftMarkdownTests", dependencies: ["SwiftMarkdown"]),
    ],
    swiftLanguageModes: [.v6]
)
