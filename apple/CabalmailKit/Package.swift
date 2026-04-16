// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CabalmailKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
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
