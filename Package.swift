// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskMapper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DiskMapper",
            path: "Sources/DiskMapper"
        ),
        .executableTarget(
            name: "DiskMapperApp",
            dependencies: ["DiskMapper"],
            path: "Sources/DiskMapperApp",
            resources: [.process("Assets.xcassets")]
        ),
        .testTarget(
            name: "DiskMapperTests",
            dependencies: ["DiskMapper"],
            path: "Tests/DiskMapperTests"
        ),
    ]
)
