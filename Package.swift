// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EdgeNowPlaying",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "EdgeNowPlaying", path: "Sources/EdgeNowPlaying")]
)
