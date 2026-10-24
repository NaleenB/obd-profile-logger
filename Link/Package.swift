// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OBDLink",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "OBDLink", targets: ["OBDLink"])
    ],
    targets: [
        .target(
            name: "OBDLink",
            path: "Sources/OBDLink",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OBDLinkTests",
            dependencies: ["OBDLink"],
            path: "Tests/OBDLinkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
