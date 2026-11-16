// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Parhlo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CompanionCore",
            targets: ["CompanionCore"]
        ),
        .executable(
            name: "ScreenCompanionApp",
            targets: ["ScreenCompanionApp"]
        )
    ],
    targets: [
        .target(
            name: "CompanionCore"
        ),
        .executableTarget(
            name: "ScreenCompanionApp",
            dependencies: ["CompanionCore"]
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"]
        )
    ]
)
