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
        // Temporarily on AttilaTheFun's fork at 148.0.0 — fixes the
        // missing-headers bug on the macOS slice that's blocked us
        // since M141 (stasel/WebRTC#145, PR #147). Swap back to the
        // upstream `stasel/WebRTC` tag once #147 merges and a real
        // release ships from there.
        .package(url: "https://github.com/AttilaTheFun/WebRTC.git", exact: "148.0.0"),
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
