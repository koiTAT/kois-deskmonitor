import Foundation
import Observation

/// 全局状态：当前快照 + 历史曲线（定长环形缓冲）。
/// 所有写入都在主线程发生，视图直接读即可。
@Observable
final class MetricsStore {
    var cpu = CPUSnapshot()
    var memory = MemorySnapshot()
    var network = NetworkSnapshot()
    var disk = DiskSnapshot()
    var gpu = GPUSnapshot()

    /// 0...1，最新值在末尾
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []

    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
    var gpuHistory: [Double] = []

    /// 性能核数量（Apple Silicon 的 P 核），用于给每核柱状图分组配色
    let performanceCoreCount: Int

    let historyCapacity = 120

    // MARK: - 可选模块
    var showProcesses: Bool
    var showCPU: Bool
    var showMemory: Bool
    var showNetwork: Bool
    var showDisk: Bool
    var showGPU: Bool

    /// 是否在面板里显示 DSH 任务进度
    var showDSTasks: Bool
    /// 是否单独占用一格菜单栏显示 DSH 任务
    var showDSTasksInMenuBar: Bool

    // MARK: - 时间与天气
    var showClockWeather: Bool

    /// 简约模式：只留 CPU 和内存两行，面板高度砍掉三分之二
    var compactMode: Bool

    /// 完整版面板宽度（可在右键菜单里调）
    var panelWidthPoints: Double

    /// 是否记住上次的位置与尺寸
    var rememberFrame: Bool

    /// 拖动结束时吸附到 DSH 窗口边缘
    var snapToDSH: Bool

    /// 用户拖过高度之后就不再按内容自适应
    var manualHeight: Bool

    /// 记住的手动高度
    var panelHeight: Double
    var now: Date = Date()
    var weather = WeatherSnapshot()

    var processes: [ProcessUsage] = []

    var showsIOSection: Bool { showNetwork || showDisk || showGPU }

    /// 全部模块都关掉时，至少留个时间栏，否则面板会空成一个标题
    var hasAnyBody: Bool {
        showCPU || showMemory || showsIOSection || showProcesses
    }

    init() {
        performanceCoreCount = Self.detectPerformanceCores()
        panelWidthPoints = (UserDefaults.standard.object(forKey: Prefs.panelWidth) as? Double) ?? 244
        rememberFrame = (UserDefaults.standard.object(forKey: Prefs.rememberFrame) as? Bool) ?? true
        snapToDSH = (UserDefaults.standard.object(forKey: Prefs.snapToDSH) as? Bool) ?? true
        manualHeight = UserDefaults.standard.bool(forKey: Prefs.manualHeight)
        panelHeight = (UserDefaults.standard.object(forKey: Prefs.panelHeight) as? Double) ?? 615

        // 默认开启进程列表，但用户关掉过就尊重用户的选择。
        // 注意不能直接用 bool(forKey:)——没设置过时它返回 false，
        // 会盖掉 registerDefaults 里的默认值。
        showProcesses = Self.flag(Prefs.showProcesses, default: true)
        showCPU = Self.flag(Prefs.showCPU, default: true)
        showMemory = Self.flag(Prefs.showMemory, default: true)
        showNetwork = Self.flag(Prefs.showNetwork, default: true)
        showDisk = Self.flag(Prefs.showDisk, default: true)
        showGPU = Self.flag(Prefs.showGPU, default: true)
        showClockWeather = Self.flag(Prefs.showClockWeather, default: true)
        showDSTasks = Self.flag(Prefs.showDSTasks, default: true)
        showDSTasksInMenuBar = Self.flag(Prefs.showDSTasksInMenuBar, default: true)
        compactMode = Self.flag(Prefs.compactMode, default: false)
    }

    func apply(_ bundle: SampleBundle) {
        // 时钟跟着采样走：反正每秒都要重绘一次，不用额外的定时器
        now = Date()
        cpu = bundle.cpu
        memory = bundle.memory
        network = bundle.network
        disk = bundle.disk
        gpu = bundle.gpu

        push(&cpuHistory, bundle.cpu.totalUsage)
        push(&memoryHistory, bundle.memory.usageRatio)
        // 速率型指标是绝对字节数，不能按 0...1 裁剪
        pushRate(&downloadHistory, bundle.network.downPerSecond)
        pushRate(&uploadHistory, bundle.network.upPerSecond)
        pushRate(&diskReadHistory, bundle.disk.readPerSecond)
        pushRate(&diskWriteHistory, bundle.disk.writePerSecond)
        push(&gpuHistory, bundle.gpu.utilization)
    }

    func apply(processes: [ProcessUsage]) {
        self.processes = processes
    }

    func resetHistory() {
        cpuHistory.removeAll(keepingCapacity: true)
        memoryHistory.removeAll(keepingCapacity: true)
        downloadHistory.removeAll(keepingCapacity: true)
        uploadHistory.removeAll(keepingCapacity: true)
        diskReadHistory.removeAll(keepingCapacity: true)
        diskWriteHistory.removeAll(keepingCapacity: true)
        gpuHistory.removeAll(keepingCapacity: true)
    }

    /// 比率型指标：裁剪到 0...1
    private func push(_ buffer: inout [Double], _ value: Double) {
        buffer.append(min(1, max(0, value)))
        if buffer.count > historyCapacity {
            buffer.removeFirst(buffer.count - historyCapacity)
        }
    }

    /// 速率型指标：不裁剪，由视图自己决定缩放上限
    private func pushRate(_ buffer: inout [Double], _ value: Double) {
        buffer.append(max(0, value))
        if buffer.count > historyCapacity {
            buffer.removeFirst(buffer.count - historyCapacity)
        }
    }

    /// 没存过值时才用默认值——直接 bool(forKey:) 在未设置时返回 false，
    /// 会悄悄盖掉 registerDefaults 的默认值。
    static func flag(_ key: String, default value: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return value }
        return defaults.bool(forKey: key)
    }

    // MARK: - 硬件信息

    /// Apple Silicon 上 `hw.perflevel0` 是性能核，`hw.perflevel1` 是能效核。
    /// 读不到（Intel 机器）就返回 0，视图退化成单色柱状图。
    private static func detectPerformanceCores() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0 else {
            return 0
        }
        return Int(value)
    }
}
