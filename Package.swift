// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mmBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MMCore", targets: ["MMCore"]),
        .executable(name: "mmctl", targets: ["mmctl"]),
        .executable(name: "mmBrowser", targets: ["MMApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MMCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "mmctl",
            dependencies: [
                "MMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MMApp",
            dependencies: ["MMCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "MMCoreTests", dependencies: ["MMCore"]),
    ]
)
