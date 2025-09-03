// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smoothscrolld",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "smoothscrolld", targets: ["smoothscrolld"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "smoothscrolld",
            dependencies: []
        )
    ]
)
