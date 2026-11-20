// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskMonitor", targets: ["DeskMonitor"])
    ],
    dependencies: [
        // DSH 任务进度：与独立版 DSHTasks 共用同一套状态项和面板卡片
        .package(path: "Vendor/DSHTasksKit")
    ],
    targets: [
        .executableTarget(
            name: "DeskMonitor",
            dependencies: [.product(name: "DSHTasksKit", package: "DSHTasksKit")],
            path: "Sources/DeskMonitor"
        )
    ]
)
