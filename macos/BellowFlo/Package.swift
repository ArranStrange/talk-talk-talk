// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BellowFlo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BellowFlo", path: "Sources/BellowFlo")
    ]
)
