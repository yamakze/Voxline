// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voxline",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Voxline", targets: ["VoxlineApp"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", revision: "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d")
    ],
    targets: [
        .target(name: "VoxlineCore"),
        .target(name: "VoxlineMedia", dependencies: ["VoxlineCore"]),
        .target(name: "VoxlineTranslation", dependencies: ["VoxlineCore"]),
        .target(name: "VoxlineWhisperKit", dependencies: ["VoxlineCore", .product(name: "WhisperKit", package: "argmax-oss-swift")], resources: [.process("Resources")]),
        .executableTarget(name: "VoxlineApp", dependencies: ["VoxlineCore", "VoxlineMedia", "VoxlineWhisperKit", "VoxlineTranslation"]),
        .testTarget(name: "VoxlineTranslationTests", dependencies: ["VoxlineTranslation", "VoxlineCore"]),
        .testTarget(name: "VoxlineCoreTests", dependencies: ["VoxlineCore"]),
        .testTarget(name: "VoxlineMediaTests", dependencies: ["VoxlineMedia", "VoxlineCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VoxlineAppTests", dependencies: ["VoxlineApp", "VoxlineCore"]),
        .testTarget(name: "VoxlineWhisperKitTests", dependencies: ["VoxlineWhisperKit"])
    ]
)
