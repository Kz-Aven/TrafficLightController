// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrafficLight",
    platforms: [.macOS(.v13)],
    targets: [
        // App 与 CLI 共享的协议模型与 Unix Socket 客户端
        .target(name: "TrafficLightCore"),
        // 红绿灯桌面 App（悬浮窗 + 状态栏 + Socket 服务）
        .executableTarget(
            name: "TrafficLight",
            dependencies: ["TrafficLightCore"],
            path: "Sources/TrafficLight",
            resources: [.process("Resources")]
        ),
        // 命令行工具（目标名避免与 App 目标仅大小写不同——APFS 大小写不敏感会互相覆盖产物；
        // 构建脚本会把产物二进制重命名为 trafficlight）
        .executableTarget(
            name: "TrafficLightCLI",
            dependencies: ["TrafficLightCore"],
            path: "Sources/TrafficLightCLI"
        ),
        .testTarget(
            name: "TrafficLightTests",
            dependencies: ["TrafficLight"],
            path: "Tests/TrafficLightTests"
        ),
    ]
)
