// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voxline",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Voxline", targets: ["VoxlineApp"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", revision: "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d")
    ],
    targets: [
        .target(name: "VoxlineCore", path: "Sources/Voxline/Core", resources: [.process("Resources")]),
        .target(name: "VoxlineMedia", dependencies: ["VoxlineCore"], path: "Sources/Voxline/Media", resources: [.process("Resources")]),
        .target(name: "VoxlineTranslation", dependencies: ["VoxlineCore"], path: "Sources/Voxline/Translation", resources: [.process("Resources")]),
        .target(name: "VoxlineWhisperKit", dependencies: ["VoxlineCore", .product(name: "WhisperKit", package: "argmax-oss-swift")], path: "Sources/Voxline/WhisperKit", resources: [.process("Resources")]),
        .target(name: "VoxlineWorkflow", dependencies: ["VoxlineCore", "VoxlineMedia", "VoxlineWhisperKit", "VoxlineTranslation"], path: "Sources/Voxline/Workflow", resources: [.process("Resources")]),
        .executableTarget(name: "VoxlineApp", dependencies: ["VoxlineCore", "VoxlineMedia", "VoxlineWhisperKit", "VoxlineTranslation", "VoxlineWorkflow"], path: "Sources/Voxline/App", resources: [.process("Resources")]),
        .testTarget(name: "VoxlineTranslationTests", dependencies: ["VoxlineTranslation", "VoxlineCore", "VoxlineMedia"]),
        .testTarget(name: "VoxlineCoreTests", dependencies: ["VoxlineCore"]),
        .testTarget(name: "VoxlineMediaTests", dependencies: ["VoxlineMedia", "VoxlineCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VoxlineAppTests", dependencies: ["VoxlineApp", "VoxlineCore", "VoxlineMedia", "VoxlineTranslation", "VoxlineWhisperKit", "VoxlineWorkflow"]),
        .testTarget(name: "VoxlineWorkflowTests", dependencies: ["VoxlineWorkflow", "VoxlineCore", "VoxlineMedia", "VoxlineWhisperKit", "VoxlineTranslation"]),
        .testTarget(name: "VoxlineWhisperKitTests", dependencies: ["VoxlineWhisperKit"])
    ]
)
