// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CabalmailKit",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0"),
        .visionOS("2.0"),
    ],
    products: [
        .library(name: "CabalmailKit", targets: ["CabalmailKit"]),
    ],
    targets: [
        .target(
            name: "CabalmailKit",
            path: "Sources/CabalmailKit",
            resources: [
                // Rich-text editor HTML + bundled marked + turndown copies
                // (vendored from react/admin/node_modules so the Apple
                // composer round-trips identically to the React one).
                // .copy preserves the folder so editor.html can find its
                // sibling marked.umd.js / turndown.js / editor-bridge.js
                // via relative <script src=...> tags.
                .copy("Compose/Resources"),
            ]
        ),
        .testTarget(
            name: "CabalmailKitTests",
            dependencies: ["CabalmailKit"],
            path: "Tests/CabalmailKitTests"
        ),
    ]
)
