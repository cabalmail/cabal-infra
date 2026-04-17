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
            path: "Sources/CabalmailKit"
        ),
        .testTarget(
            name: "CabalmailKitTests",
            dependencies: ["CabalmailKit"],
            path: "Tests/CabalmailKitTests"
        ),
    ]
)
