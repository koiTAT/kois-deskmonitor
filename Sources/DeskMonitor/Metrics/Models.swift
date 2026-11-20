import AppKit

// MARK: - 内存压力等级
//
// 来自 sysctl kern.memorystatus_vm_pressure_level，取值 1 / 2 / 4。
enum PressureLevel: Int, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(rawLevel: Int32) {
        switch rawLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "严重"
        }
    }
}

// MARK: - CPU 快照
struct CPUSnapshot: Equatable {
    /// 系统整体占用率 0...1
    var totalUsage: Double = 0
    /// 用户态占比 0...1
    var user: Double = 0
    /// 内核态占比 0...1
    var system: Double = 0
    /// 空闲占比 0...1
    var idle: Double = 1
    /// 每个逻辑核的占用率 0...1
    var perCore: [Double] = []

    var coreCount: Int { perCore.count }
}

// MARK: - 内存快照
struct MemorySnapshot: Equatable {
    var total: UInt64 = 0
    /// 应用内存（internal - purgeable）
    var appMemory: UInt64 = 0
    /// 联动内存，不可换出
    var wired: UInt64 = 0
    /// 压缩内存
    var compressed: UInt64 = 0
    /// 文件缓存（external + purgeable）
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: PressureLevel = .normal

    /// 已用 = 应用 + 联动 + 压缩（与「活动监视器」口径一致）
    var used: UInt64 { appMemory &+ wired &+ compressed }

    /// 未被任何东西占用的部分
    var free: UInt64 {
        let remainder = total &- min(total, used &+ cachedFiles)
        return remainder
    }

    var usageRatio: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
}

// MARK: - 窗口层级
enum WindowLevelMode: String, CaseIterable {
    /// 永远压在所有窗口之上
    case floating
    /// 贴在壁纸上方，所有窗口都能盖住它
    case desktop
    /// 普通窗口层级，会被前端 App 覆盖
    case normal

    var title: String {
        switch self {
        case .floating: return "悬浮置顶"
        case .desktop: return "桌面层"
        case .normal: return "普通窗口"
        }
    }

    var level: NSWindow.Level {
        switch self {
        case .floating: return .floating
        case .desktop: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        case .normal: return .normal
        }
    }
}
