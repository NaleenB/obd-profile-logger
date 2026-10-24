// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OBDProbe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Link")
    ],
    targets: [
        .executableTarget(
            name: "OBDProbe",
            dependencies: [
                .product(name: "OBDCore", package: "Core"),
                .product(name: "OBDLink", package: "Link")
            ],
            path: "Sources/OBDProbe"
        ),
        .testTarget(
            name: "OBDProbeTests",
            dependencies: ["OBDProbe"],
            path: "Tests/OBDProbeTests"
        )
    ]
)
