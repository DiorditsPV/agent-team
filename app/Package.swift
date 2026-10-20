// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentTeam",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentTeamApp", targets: ["AgentTeamApp"]),
        .library(name: "AgentTeamCore", targets: ["AgentTeamCore"]),
    ],
    targets: [
        .target(name: "AgentTeamCore"),
        .executableTarget(name: "AgentTeamApp", dependencies: ["AgentTeamCore"]),
        .testTarget(
            name: "AgentTeamCoreTests",
            dependencies: ["AgentTeamCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
