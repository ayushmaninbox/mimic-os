// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iDroid",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "iDroid",
            path: "Sources/iDroid"
        )
    ]
)
