// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KinroxMusic",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MusicCore", targets: ["MusicCore"]),
        .library(name: "SpotifyWebAPI", targets: ["SpotifyWebAPI"]),
    ],
    targets: [
        .target(name: "MusicCore"),
        .target(name: "SpotifyWebAPI", dependencies: ["MusicCore"]),
        .testTarget(name: "SpotifyWebAPITests", dependencies: ["SpotifyWebAPI"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
    ],
    swiftLanguageModes: [.v6]
)
