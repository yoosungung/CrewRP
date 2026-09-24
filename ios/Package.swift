// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrewRPCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CrewRPCore", targets: ["CrewRPCore"]),
    ],
    targets: [
        .target(name: "CrewRPCore"),
        .testTarget(name: "CrewRPCoreTests", dependencies: ["CrewRPCore"]),
    ]
)
