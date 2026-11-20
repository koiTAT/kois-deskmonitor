// swift-tools-version:5.9
import PackageDescription

/// DSH 任务进度读取（从 dsh-workspace-progress/menubar 收进来的只读副本）。
/// DeskMonitor 只需要其中的读取与建模部分，因此这里只保留 library 目标。
let package = Package(
    name: "DSHTasksKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DSHTasksKit", targets: ["DSHTasksKit"])
    ],
    targets: [
        .target(name: "DSHTasksKit", path: "Sources/DSHTasksKit")
    ]
)
