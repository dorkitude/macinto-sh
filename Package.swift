// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Macinto",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Macinto",
            path: "Sources/Macinto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
