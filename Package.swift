// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectFileMakerAdminAPI",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PerfectFileMakerAdminAPI", targets: ["PerfectFileMakerAdminAPI"]),
    ],
    dependencies: [
        // Linux-only: backs FMAdminInsecureLinuxTransport, the pinned-cert
        // equivalent of FMAdminInsecureTLS.swift's Darwin-only delegate.
        // Versions matched to Perfect-NIO/Perfect-SMTP's existing pins so
        // this resolves alongside them without divergent requirements.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "PerfectFileMakerAdminAPI",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client",
                          condition: .when(platforms: [.linux])),
                .product(name: "NIOCore", package: "swift-nio",
                          condition: .when(platforms: [.linux])),
                .product(name: "NIOHTTP1", package: "swift-nio",
                          condition: .when(platforms: [.linux])),
                .product(name: "NIOSSL", package: "swift-nio-ssl",
                          condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(name: "PerfectFileMakerAdminAPITests", dependencies: ["PerfectFileMakerAdminAPI"]),
    ]
)
