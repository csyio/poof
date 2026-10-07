// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "poof",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "poof", targets: ["poof"]),
        .executable(name: "PoofApp", targets: ["PoofApp"]),
        .library(name: "PoofCore", targets: ["PoofCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PoofCore"),
        .executableTarget(
            name: "poof",
            dependencies: [
                "PoofCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "PoofApp", dependencies: ["PoofCore"]),
        .testTarget(name: "PoofCoreTests", dependencies: ["PoofCore"]),
    ]
)
