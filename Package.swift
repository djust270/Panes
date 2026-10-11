// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .executable(name: "ExplorerApp", targets: ["ExplorerApp"]),
    ],
    targets: [
        .target(
            name: "ExplorerCore",
            linkerSettings: [.linkedFramework("CoreServices")]
        ),
        .executableTarget(
            name: "ExplorerApp",
            dependencies: ["ExplorerCore"]
        ),
        .testTarget(
            name: "ExplorerCoreTests",
            dependencies: ["ExplorerCore"]
        ),
    ]
)
