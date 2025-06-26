// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "olleh",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
        .package(url: "https://github.com/loopwork-ai/ollama-swift", from: "1.8.0"),
        .package(url: "https://github.com/loopwork-ai/bestline-swift", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "olleh",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Ollama", package: "ollama-swift"),
                .product(name: "Bestline", package: "bestline-swift"),
            ]
        )
    ]
)
