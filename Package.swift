// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentCurtain",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentCurtainCore", targets: ["AgentCurtainCore"]),
        .executable(name: "AgentCurtain", targets: ["AgentCurtain"]),
        .executable(name: "AgentCurtainRestoreWatchdog", targets: ["AgentCurtainRestoreWatchdog"]),
    ],
    targets: [
        .target(name: "AgentCurtainCore"),
        .executableTarget(
            name: "AgentCurtain",
            dependencies: ["AgentCurtainCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "AgentCurtainRestoreWatchdog",
            dependencies: ["AgentCurtainCore"]
        ),
        .testTarget(
            name: "AgentCurtainCoreTests",
            dependencies: ["AgentCurtainCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
