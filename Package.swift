// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentBox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AgentBox", targets: ["AgentBox"])
    ],
    targets: [
        .executableTarget(
            name: "AgentBox",
            resources: [
                .copy("Resources/Scripts"),
                .copy("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "AgentBoxTests",
            dependencies: ["AgentBox"]
        )
    ]
)
