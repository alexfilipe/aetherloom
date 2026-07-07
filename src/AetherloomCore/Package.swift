// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AetherloomCore",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AetherloomCore",
            targets: ["AetherloomCore"]
        ),
        .library(
            name: "AetherloomIntelligence",
            targets: ["AetherloomIntelligence"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AetherloomCore"
        ),
        .target(
            name: "AetherloomIntelligence",
            dependencies: ["AetherloomCore"]
        ),
        .testTarget(
            name: "AetherloomCoreTests",
            dependencies: ["AetherloomCore", "AetherloomIntelligence"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
