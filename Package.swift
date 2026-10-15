// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Macinto",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Macinto",
            dependencies: ["MacintoGeometry"],
            path: "Sources/Macinto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure geometry (no AppKit, no permissions), so it can be unit tested.
        .target(
            name: "MacintoGeometry",
            path: "Sources/MacintoGeometry",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacintoTests",
            dependencies: ["MacintoGeometry"],
            path: "Tests/MacintoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
