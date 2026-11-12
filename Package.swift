// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HatchPet",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HatchPet",
            path: "Sources/HatchPet",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
