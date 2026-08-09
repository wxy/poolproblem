// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "poolproblem",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskReservoirCore", targets: ["DiskReservoirCore"]),
        .executable(name: "poolproblem", targets: ["poolproblem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DiskReservoirCore"),
        .executableTarget(
            name: "poolproblem",
            dependencies: [
                "DiskReservoirCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DiskReservoirCoreTests", dependencies: ["DiskReservoirCore"]),
        .testTarget(name: "PoolProblemCLITests", dependencies: ["poolproblem"]),
    ]
)
