// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JetKVMProtocol",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JetKVMProtocol", targets: ["JetKVMProtocol"]),
    ],
    targets: [
        .target(name: "JetKVMProtocol"),
        .testTarget(name: "JetKVMProtocolTests", dependencies: ["JetKVMProtocol"]),
    ]
)
