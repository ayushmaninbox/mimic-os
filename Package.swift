// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MimicOS",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MimicOS",
            path: "Sources/MimicOS"
        )
    ]
)
