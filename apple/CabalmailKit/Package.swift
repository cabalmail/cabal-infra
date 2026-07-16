// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CabalmailKit",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0"),
        .visionOS("2.0"),
        .watchOS("11.0"),
    ],
    products: [
        .library(name: "CabalmailKit", targets: ["CabalmailKit"]),
    ],
    targets: [
        .target(
            name: "CabalmailKit",
            path: "Sources/CabalmailKit",
            resources: [
                // Rich-text editor HTML + bridge script. .copy preserves
                // the folder so editor.html can find its sibling
                // editor-bridge.js via a relative <script src=...> tag.
                // The folder is deliberately NOT named "Resources": a
                // top-level "Resources/" directory inside a shallow
                // iOS/watchOS bundle makes `codesign` reject the bundle
                // as "format unrecognized" (ambiguous shallow-vs-deep
                // layout), which breaks any locally signed build.
                .copy("Compose/WebAssets"),
            ]
        ),
        .testTarget(
            name: "CabalmailKitTests",
            dependencies: ["CabalmailKit"],
            path: "Tests/CabalmailKitTests"
        ),
    ]
)
