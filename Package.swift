// swift-tools-version: 6.0
import PackageDescription
import Foundation

// 裸 SwiftPM 可执行文件也必须允许资源包按系统语言选择本地化。
let localizationLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
        "-Xlinker", URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("scripts/LocalizationInfo.plist").path,
    ]),
]

let package = Package(
    name: "mmBrowser",
    defaultLocalization: "en",
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
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "mmctl",
            dependencies: [
                "MMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.process("Resources")],
            linkerSettings: localizationLinkerSettings
        ),
        .executableTarget(
            name: "MMApp",
            dependencies: ["MMCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources")],
            linkerSettings: localizationLinkerSettings
        ),
        .testTarget(name: "MMCoreTests", dependencies: ["MMCore"]),
    ]
)
