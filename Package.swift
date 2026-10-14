// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .executable(name: "ExplorerApp", targets: ["ExplorerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "ExplorerCore",
            linkerSettings: [.linkedFramework("CoreServices")]
        ),
        .executableTarget(
            name: "ExplorerApp",
            dependencies: [
                "ExplorerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        .testTarget(
            name: "ExplorerCoreTests",
            dependencies: ["ExplorerCore"]
        ),
    ]
)
