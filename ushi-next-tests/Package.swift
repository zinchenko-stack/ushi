// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UshiNextCoreTests",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UshiNextCore", targets: ["UshiNextCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "UshiNextCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "UshiNextCoreTests",
            dependencies: ["UshiNextCore"]
        ),
    ]
)
