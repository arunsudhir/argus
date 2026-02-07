// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Argus", targets: ["Argus"])
    ],
    targets: [
        .executableTarget(
            name: "Argus",
            dependencies: []
        )
    ]
)
