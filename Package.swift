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
            path: "Sources/TypelessSwitchboard",
            // v2.6.0：会话/额度脚本的唯一来源。
            // 以前它是以字符串内嵌在 Swift 源码里、仓库 scripts/ 下再放一份，
            // 两份分叉后线上跑的和仓库里的不是同一个东西。
            // 现在只此一份，由 build-app.sh 随包分发。
            resources: [
                .copy("Resources/extract-active-session.js"),
                .copy("Resources/write-active-session.js")
            ]
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
