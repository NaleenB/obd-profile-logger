// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OBDCore",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "OBDCore", targets: ["OBDCore"])
    ],
    targets: [
        .target(name: "OBDCore", path: "Sources/OBDCore"),
        .testTarget(name: "OBDCoreTests", dependencies: ["OBDCore"], path: "Tests/OBDCoreTests")
    ]
)
