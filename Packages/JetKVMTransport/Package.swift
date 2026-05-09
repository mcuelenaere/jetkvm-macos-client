// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JetKVMTransport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JetKVMTransport", targets: ["JetKVMTransport"]),
    ],
    dependencies: [
        .package(path: "../JetKVMProtocol"),
        // M140 is the last version that ships proper macOS headers.
        // M141..M147 only ship an umbrella WebRTC.h on the macos slice
        // — the individual `RTCFoo.h` headers it references are missing,
        // which breaks the Clang module build. Tracked at stasel/WebRTC#145.
        // Re-evaluate when a fixed release lands.
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
