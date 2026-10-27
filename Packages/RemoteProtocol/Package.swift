// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemoteProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"]),
        .library(name: "RemoteTransport", targets: ["RemoteTransport"]),
        .executable(name: "kinrox-cli", targets: ["kinrox-cli"]),
    ],
    targets: [
        .target(name: "RemoteProtocol"),
        .target(name: "RemoteTransport", dependencies: ["RemoteProtocol"]),
        .executableTarget(name: "kinrox-cli", dependencies: ["RemoteTransport"]),
        .testTarget(
            name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "RemoteTransportTests", dependencies: ["RemoteTransport"]),
    ],
    swiftLanguageModes: [.v6]
)
