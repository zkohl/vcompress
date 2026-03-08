// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vcompress",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "vcompress",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/vcompress"
        ),
        .testTarget(
            name: "vcompressTests",
            dependencies: ["vcompress"],
            path: "Tests/vcompressTests",
            exclude: ["Integration/Fixtures"]
        ),
    ]
)
