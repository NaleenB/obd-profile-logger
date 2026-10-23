// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OBDProbe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .executableTarget(
            name: "OBDProbe",
            dependencies: [
                .product(name: "OBDCore", package: "Core")
            ],
            path: "Sources/OBDProbe"
        )
    ]
)
