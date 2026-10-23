// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OBDProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OBDProbe",
            path: "Sources/OBDProbe"
        )
    ]
)
