// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JetKVMTransport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JetKVMTransport", targets: ["JetKVMTransport"]),
    ],
    dependencies: [
        .package(path: "../JetKVMProtocol"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "147.0.0"),
    ],
    targets: [
        .target(
            name: "JetKVMTransport",
            dependencies: [
                "JetKVMProtocol",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(name: "JetKVMTransportTests", dependencies: ["JetKVMTransport"]),
    ]
)
