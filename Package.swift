// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexProviderSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexProviderCore", targets: ["CodexProviderCore"]),
        .executable(name: "CodexProviderSwitcher", targets: ["CodexProviderSwitcher"]),
    ],
    targets: [
        .target(name: "CodexProviderCore"),
        .executableTarget(
            name: "CodexProviderSwitcher",
            dependencies: ["CodexProviderCore"]
        ),
        .testTarget(
            name: "CodexProviderCoreTests",
            dependencies: ["CodexProviderCore"]
        ),
    ]
)
