// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPetNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexPetNotch", targets: ["CodexPetNotch"])
    ],
    targets: [
        .executableTarget(
            name: "CodexPetNotch",
            resources: [.copy("Resources")]
        )
    ]
)
