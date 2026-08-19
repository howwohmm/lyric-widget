// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LyricBar", path: "Sources/LyricBar",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
