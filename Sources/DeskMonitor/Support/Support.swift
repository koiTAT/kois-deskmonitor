import Foundation

// MARK: - 格式化
enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        formatter.isAdaptive = true
        return formatter
    }()

    static func size(_ bytes: UInt64) -> String {
        // ByteCountFormatter 会把 0 格式化成 "Zero KB"，这里直接短路
        guard bytes > 0 else { return "0 B" }
        return byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", min(1, max(0, ratio)) * 100)
    }

    static func percent(_ ratio: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f%%", min(1, max(0, ratio)) * 100)
    }

    /// 单进程 CPU：不做 100% 截断，多线程应用可以超过
    static func percentCPU(_ ratio: Double) -> String {
        String(format: "%.0f%%", max(0, ratio) * 100)
    }

    /// 速率：1.2M/s、340K/s
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let value = max(0, bytesPerSecond)

        if value >= gb { return String(format: "%.1fG/s", value / gb) }
        if value >= mb { return String(format: "%.1fM/s", value / mb) }
        if value >= kb { return String(format: "%.0fK/s", value / kb) }
        return String(format: "%.0fB/s", value)
    }

    /// 紧凑写法，用于空间紧张的一行图例：8.1G / 512M
    static func compact(_ bytes: UInt64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let value = Double(bytes)

        if value >= gb { return String(format: "%.1fG", value / gb) }
        if value >= mb { return String(format: "%.0fM", value / mb) }
        if value >= kb { return String(format: "%.0fK", value / kb) }
        return "0"
    }
}

// MARK: - 用户偏好 key
enum Prefs {
    static let levelMode = "dm.levelMode"
    static let clickThrough = "dm.clickThrough"
    static let opacity = "dm.opacity"
    static let interval = "dm.interval"
    static let panelVisible = "dm.panelVisible"
    static let showProcesses = "dm.showProcesses"
    static let showNetwork = "dm.showNetwork"
    static let showDisk = "dm.showDisk"
    static let showGPU = "dm.showGPU"
    static let showClockWeather = "dm.showClockWeather"
    static let showDSTasks = "dm.showDSTasks"
    static let showDSTasksInMenuBar = "dm.showDSTasksInMenuBar"
    static let compactMode = "dm.compactMode"
    static let panelWidth = "dm.panelWidth"
    static let rememberFrame = "dm.rememberFrame"
    static let snapToDSH = "dm.snapToDSH"
    static let manualHeight = "dm.manualHeight"
    static let panelHeight = "dm.panelHeight"
    static let showCPU = "dm.showCPU"
    static let showMemory = "dm.showMemory"
    static let cityName = "dm.cityName"
    static let cityLatitude = "dm.cityLatitude"
    static let cityLongitude = "dm.cityLongitude"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            levelMode: WindowLevelMode.floating.rawValue,
            clickThrough: false,
            opacity: 1.0,
            interval: 1.0,
            panelVisible: true,
            showProcesses: true,
            showNetwork: true,
            showDisk: true,
            showGPU: true,
            showClockWeather: true,
            showDSTasks: true,
            showDSTasksInMenuBar: true,
            compactMode: false,
            showCPU: true,
            showMemory: true,
        ])
    }
}

// MARK: - 应用内通知
extension Notification.Name {
    /// 双击面板（标题行 / 时间行）切换简约 ↔ 完整
    static let dmResizeBegan = Notification.Name("dm.resizeBegan")
    static let dmResizeEnded = Notification.Name("dm.resizeEnded")
    static let dmManualResize = Notification.Name("dm.manualResize")
    static let dmToggleCompact = Notification.Name("dm.toggleCompact")
}

// MARK: - 沙盒能力探测
//
// 这是给「将来上架 App Store」预留的开关。沙盒里：
//   - 系统级 CPU / 内存 / 磁盘 / 网络 依然可读
//   - 其他进程的信息（proc_pidinfo）基本读不到
//   - SMC 温度、风扇 完全不可用
// 用运行时环境变量判断，不需要两套代码。
enum Capabilities {
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 是否允许读取单个进程的详情
    static var canReadProcessList: Bool {
        !isSandboxed
    }

    /// 是否允许读取 SMC（温度 / 风扇）
    static var canReadSMC: Bool {
        !isSandboxed
    }
}
