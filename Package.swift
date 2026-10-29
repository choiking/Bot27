// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bot27",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Bot27", path: "Sources/Bot27")
    ]
)
