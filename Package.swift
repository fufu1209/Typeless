// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypelessSwitchboard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TypelessSwitchboard", targets: ["TypelessSwitchboard"]),
        .executable(name: "OperationalFeatureChecks", targets: ["OperationalFeatureChecks"]),
        .executable(name: "AutomationSmokeChecks", targets: ["AutomationSmokeChecks"])
    ],
    targets: [
        .target(
            name: "TypelessSwitchboardCore",
            path: "Sources/TypelessSwitchboardCore"
        ),
        .executableTarget(
            name: "TypelessSwitchboard",
            dependencies: ["TypelessSwitchboardCore"],
            path: "Sources/TypelessSwitchboard"
        ),
        .executableTarget(
            name: "OperationalFeatureChecks",
            dependencies: ["TypelessSwitchboardCore"],
            path: "Tests/OperationalFeatureChecks"
        ),
        .executableTarget(
            name: "AutomationSmokeChecks",
            dependencies: ["TypelessSwitchboardCore"],
            path: "Tests/AutomationSmokeChecks"
        )
    ]
)
