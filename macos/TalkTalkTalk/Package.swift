// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TalkTalkTalk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TalkTalkTalk", path: "Sources/TalkTalkTalk")
    ]
)
