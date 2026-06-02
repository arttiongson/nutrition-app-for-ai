// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NutritionCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NutritionCore", targets: ["NutritionCore"]),
    ],
    targets: [
        .target(name: "NutritionCore"),
        // Runnable under the CLI tools (`swift run NutritionCoreVerify`) — XCTest/Testing
        // need full Xcode, so this is the no-Xcode verification path.
        .executableTarget(name: "NutritionCoreVerify", dependencies: ["NutritionCore"]),
        // Live check for NutritionAuth against the real backend (env-driven; see main.swift).
        .executableTarget(name: "NutritionAuthLive", dependencies: ["NutritionCore"]),
        // Full test suite for Xcode / CI (Swift Testing).
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"]),
    ]
)
