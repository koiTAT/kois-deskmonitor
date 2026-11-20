import DSHTasksKit
import SwiftUI

struct MonitorView: View {
    let store: MetricsStore
    /// 离屏渲染时关掉毛玻璃（NSVisualEffectView 在 ImageRenderer 里出不来）
    var useVibrancy: Bool = true
    /// 离屏渲染时关掉 NSViewRepresentable（否则会画出一个黄色占位符）
    var interactive: Bool = true
    /// DSH 任务卡片的数据源；离屏渲染时不传
    var taskMonitor: TaskMonitor?

    /// 完整版 244（贴合 DSH 侧栏宽度，不压到对话区）；简约模式是个 104×104 的方块
    private var panelWidth: CGFloat {
        store.compactMode ? 104 : CGFloat(store.panelWidthPoints)
    }


    var body: some View {
        VStack(spacing: 0) {
            if store.compactMode {
                compactSquare
            } else {
                if store.showClockWeather {
                    clockBar
                    separator
                }
                header
                if store.showDSTasks, let taskMonitor {
                    separator
                    DSTaskCard(monitor: taskMonitor)
                }
                if store.showCPU {
                    separator
                    cpuSection
                }
                if store.showMemory {
                    separator
                    memorySection
                }
                if store.showsIOSection {
                    separator
                    ioSection
                }
                if store.showProcesses {
                    separator
                    processSection
                }
            }
        }
        .frame(width: store.compactMode ? 104 : CGFloat(store.panelWidthPoints))
        .background {
            if useVibrancy {
                VisualEffectBackground()
                    .overlay(Color.black.opacity(0.16))
            } else {
                Color(red: 0.105, green: 0.107, blue: 0.118)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 标题栏（可拖拽）

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(warningColor ?? Palette.cpu)
                .frame(width: 6, height: 6)
                .shadow(color: (warningColor ?? Palette.cpu).opacity(0.9), radius: 3)

            Text("DeskMonitor")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer(minLength: 4)

            Text(coreSummary)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.32))
                .help(coreSummaryHelp)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background {
            if interactive {
                WindowDragArea(onDoubleClick: toggleCompact)
            } else {
                Color.clear
            }
        }
    }

    /// Apple Silicon 上性能核一定排在最后 N 个（实测验证：4 个单线程满载进程
    /// 只把最后 4 根柱子打满），所以这里用 P + E 的写法。
    private var coreSummary: String {
        let total = store.cpu.coreCount
        let performance = store.performanceCoreCount
        guard performance > 0, performance < total else { return "\(total) 核" }
        return "\(performance)P + \(total - performance)E"
    }

    private var coreBarsHelp: String {
        let total = store.cpu.coreCount
        let performance = store.performanceCoreCount
        guard performance > 0, performance < total else {
            return "每根柱子对应一个处理器核心，编号 1–\(total)，高度表示该核心当前的占用率。"
        }
        let efficiency = total - performance
        return "每根柱子对应一个处理器核心，编号 1–\(total)。"
            + "1–\(efficiency) 是能效核 E（暗色，省电），\(efficiency + 1)–\(total) 是性能核 P（亮色，快但费电）。"
    }

    private var coreSummaryHelp: String {
        let total = store.cpu.coreCount
        let performance = store.performanceCoreCount
        guard performance > 0, performance < total else {
            return "共 \(total) 个处理器核心，柱子越多表示可以同时干越多活。"
        }
        return "共 \(total) 个核心：\(performance) 个性能核（干活快、费电）+ \(total - performance) 个能效核（省电）。下面柱状图里亮色是性能核，暗色是能效核。"
    }

    /// 双击面板任意拖拽区：简约 ↔ 完整，不必再翻菜单
    private func toggleCompact() {
        NotificationCenter.default.post(name: .dmToggleCompact, object: nil)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: - 简约模式

    /// 104×104 的方块：时间在上，CPU / 内存两个数字在下。
    /// 刻意不放进度条——方块太小，条短到看不出比例，反而占地方。
    private var compactSquare: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.timeFormatter.string(from: store.now))
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .help(Self.fullDateFormatter.string(from: store.now))

            Spacer(minLength: 4)

            if store.showCPU {
                compactMetricRow(
                    label: "CPU",
                    value: Fmt.percent(store.cpu.totalUsage),
                    color: Palette.cpu
                )
            }

            Spacer(minLength: 5)

            if store.showMemory {
                compactMetricRow(
                    label: "内存",
                    value: Fmt.percent(store.memory.usageRatio),
                    color: memoryAccentColor
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 104, height: 104, alignment: .topLeading)
        .help(compactHelp)
        .background {
            if interactive {
                WindowDragArea(onDoubleClick: toggleCompact)
            } else {
                Color.clear
            }
        }
    }

    private func compactMetricRow(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            // 数值是主角，绝不允许被压缩成 "3..."
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private var compactHelp: String {
        "CPU \(Fmt.percent(store.cpu.totalUsage))"
            + "（用户 \(Fmt.percent(store.cpu.user))，系统 \(Fmt.percent(store.cpu.system))）\n"
            + "内存 \(Fmt.size(store.memory.used)) / \(Fmt.size(store.memory.total))，"
            + "压力\(store.memory.pressure.label)，"
            + "交换 \(store.memory.swapUsed > 0 ? Fmt.size(store.memory.swapUsed) : "未启用")"
    }

    /// 内存的强调色：交换吃紧时变黄/红
    private var memoryAccentColor: Color {
        switch swapSeverity(store.memory) {
        case 2: return Palette.danger
        case 1: return Palette.warn
        default: return Palette.appMemory
        }
    }

    // MARK: - 时间 / 天气

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    /// 简约模式只有 170pt 宽，日期压到最短：11月17日 → 11/17（星期放进悬停提示）
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// 悬停时给出完整日期
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    private var clockBar: some View {
        HStack(spacing: 7) {
            Text(Self.timeFormatter.string(from: store.now))
                .font(.system(size: store.compactMode ? 12 : 13,
                             weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
                .help(store.compactMode ? Self.fullDateFormatter.string(from: store.now) : "")

            if !store.compactMode {
                Text(Self.dateFormatter.string(from: store.now))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 0)

            // 简约模式只要时间：天气属于「额外信息」，不该占这个位置
            if !store.compactMode {
                weatherView
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background {
            if interactive {
                WindowDragArea(onDoubleClick: toggleCompact)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var weatherView: some View {
        let weather = store.weather
        if weather.isAvailable, let temperature = weather.temperature {
            HStack(spacing: 4) {
                Image(systemName: weather.symbolName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.7))

                // 光有图标不够直观：「阴」「雷阵雨」这种文字才是人真正关心的
                if !weather.condition.isEmpty {
                    Text(weather.condition)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }

                Text("\(Int(temperature.rounded()))°")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .help(weatherHelp(weather))
        } else {
            Text(weather.cityName.isEmpty ? "天气未设置" : "天气获取中…")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
                .help("右键 → 设置城市，可以显示当地天气。")
        }
    }

    private func weatherHelp(_ weather: WeatherSnapshot) -> String {
        var parts: [String] = []
        if !weather.cityName.isEmpty { parts.append(weather.cityName) }
        if !weather.condition.isEmpty { parts.append(weather.condition) }
        if let updated = weather.updatedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            parts.append("更新于 \(formatter.string(from: updated))")
        }
        return "天气数据来自 Open-Meteo（免费公开接口），每 15 分钟刷新一次。\n" + parts.joined(separator: " · ")
    }

    // MARK: - CPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionLabel("CPU", systemImage: "cpu")
                Spacer(minLength: 0)
                Text(Fmt.percent(store.cpu.totalUsage))
                    .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .help("全部核心的平均占用率（0–100%），下面的大数字是每核占用率。")
            }
            .padding(.bottom, 7)

            Sparkline(values: store.cpuHistory, color: Palette.cpu)
                .frame(height: 38)

            CoreBars(values: store.cpu.perCore, performanceCount: store.performanceCoreCount)
                .help(coreBarsHelp)
                .padding(.top, 9)

            HStack(spacing: 10) {
                DetailLabel(title: "用户", value: Fmt.percent(store.cpu.user))
                DetailLabel(title: "系统", value: Fmt.percent(store.cpu.system))
                DetailLabel(title: "空闲", value: Fmt.percent(store.cpu.idle))
                Spacer(minLength: 0)
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 内存

    private var memorySection: some View {
        let memory = store.memory
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionLabel("内存", systemImage: "memorychip")
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Fmt.size(memory.used))
                        .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("/ \(Fmt.size(memory.total))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .padding(.bottom, 8)

            SegmentedBar(
                segments: [
                    .init(ratio: ratio(memory.appMemory, of: memory.total), color: Palette.appMemory),
                    .init(ratio: ratio(memory.wired, of: memory.total), color: Palette.wired),
                    .init(ratio: ratio(memory.compressed, of: memory.total), color: Palette.compressed),
                    .init(ratio: ratio(memory.cachedFiles, of: memory.total), color: Palette.cached.opacity(0.30)),
                ],
                height: 9
            )

            // 明细三段：应用 / 联动 / 压缩
            HStack(spacing: 0) {
                DetailLabel(title: "应用", value: Fmt.compact(memory.appMemory), color: Palette.appMemory.opacity(0.85))
                    .help("应用内存：App 自己占用的匿名内存（不含文件缓存）。系统紧张时会被压缩或换出到磁盘。")
                Spacer(minLength: 0)
                DetailLabel(title: "联动", value: Fmt.compact(memory.wired), color: Palette.wired.opacity(0.85))
                    .help("联动内存（Wired）：内核与驱动占用，永远不能被换出或压缩，必须常驻物理内存。显卡、内核缓冲都算在这里。")
                Spacer(minLength: 0)
                DetailLabel(title: "压缩", value: Fmt.compact(memory.compressed), color: Palette.compressed.opacity(0.85))
                    .help("压缩内存：被就地压缩的页。Mac 会优先压缩而不是写交换文件，所以这部分仍然占用物理内存。")
            }
            .padding(.top, 7)

            HStack(spacing: 8) {
                swapIndicator(memory)
                Spacer(minLength: 0)
                StatusBadge(text: memory.pressure.label, color: Palette.pressure(memory.pressure))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - I/O（网络 / 磁盘 / GPU）

    private var ioSection: some View {
        let network = store.network
        let disk = store.disk
        let gpu = store.gpu

        let networkScale = [64 * 1024.0, store.downloadHistory.max() ?? 0, store.uploadHistory.max() ?? 0].max() ?? 0
        let diskScale = [64 * 1024.0, store.diskReadHistory.max() ?? 0, store.diskWriteHistory.max() ?? 0].max() ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            if store.showNetwork {
                ioRow(
                    label: "网络",
                    values: [
                        ("↓", Fmt.rate(network.downPerSecond), Palette.netDown),
                        ("↑", Fmt.rate(network.upPerSecond), Palette.netUp),
                    ]
                ) {
                    ZStack {
                        Sparkline(
                            values: store.uploadHistory,
                            color: Palette.netUp,
                            lineWidth: 1.2,
                            showHead: false,
                            fullScale: networkScale
                        )
                        Sparkline(
                            values: store.downloadHistory,
                            color: Palette.netDown,
                            lineWidth: 1.4,
                            showHead: false,
                            fullScale: networkScale
                        )
                    }
                }
            }

            if store.showDisk {
                ioRow(
                    label: "磁盘",
                    values: [
                        ("读", Fmt.rate(disk.readPerSecond), Palette.diskIO),
                        ("写", Fmt.rate(disk.writePerSecond), Palette.diskIO.opacity(0.62)),
                    ]
                ) {
                    ZStack {
                        Sparkline(
                            values: store.diskWriteHistory,
                            color: Palette.diskIO.opacity(0.55),
                            lineWidth: 1.2,
                            showHead: false,
                            fullScale: diskScale
                        )
                        Sparkline(
                            values: store.diskReadHistory,
                            color: Palette.diskIO,
                            lineWidth: 1.4,
                            showHead: false,
                            fullScale: diskScale
                        )
                    }
                }

                HStack(spacing: 4) {
                    Text("剩余")
                        .foregroundStyle(.white.opacity(0.30))
                    Text("\(Fmt.size(disk.available)) / \(Fmt.size(disk.capacity))")
                        .foregroundStyle(.white.opacity(0.48))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .padding(.top, 5)
            }

            if store.showGPU {
                ioRow(
                    label: "GPU",
                    values: [
                        (gpu.available ? Fmt.percent(gpu.utilization) : "不可用", "", Palette.gpu),
                    ]
                ) {
                    SegmentedBar(
                        segments: [.init(ratio: gpu.utilization, color: Palette.gpu)],
                        height: 5
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func ioRow<Graph: View>(
        label: String,
        values: [(symbol: String, text: String, color: Color)],
        @ViewBuilder graph: () -> Graph
    ) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 24, alignment: .leading)

            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 2) {
                    if !item.symbol.isEmpty {
                        Text(item.symbol)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    }
                }
                .foregroundStyle(item.color.opacity(0.9))
                .frame(width: 58, alignment: .leading)
            }

            Spacer(minLength: 0)

            graph()
                .frame(width: 78, height: 14)
        }
        .frame(height: 19)
    }

    // MARK: - 进程（可选模块）

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionLabel("进程", systemImage: "list.bullet")
                Spacer(minLength: 0)
                Text("CPU")
                    .frame(width: 34, alignment: .trailing)
                    .help("100% = 吃满 1 个核心，不是整台电脑的 100%。你的机器有 \(store.cpu.coreCount) 个核，所以 100% 只占整机 \(100 / max(1, store.cpu.coreCount))%。超过 100% 说明它在同时用多个核，属于正常现象。")
                Text("内存")
                    .frame(width: 46, alignment: .trailing)
                    .help("该 App 所有进程的常驻内存（RSS）之和。共享库会被重复计算，所以会比「活动监视器」偏高。")
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.white.opacity(0.22))
            .padding(.bottom, 4)

            if store.processes.isEmpty {
                Text(store.showProcesses ? "采样中…" : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(height: 15)
            } else {
                ForEach(store.processes) { item in
                    processRow(item)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 88, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func processRow(_ item: ProcessUsage) -> some View {
        HStack(spacing: 6) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 12, height: 12)

            Text(item.name)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if item.processCount > 1 {
                Text("×\(item.processCount)")
                    .font(.system(size: 8, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.25))
                    .help("\(item.name) 实际开了 \(item.processCount) 个进程（1 个主程序 + \(item.processCount - 1) 个辅助进程，负责网络、渲染、音频等）。这一行的 CPU 和内存是它们加起来的总和。")
            }

            Spacer(minLength: 2)

            Text(Fmt.percentCPU(item.cpu))
                .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(processCPUColor(item.cpu))
                .frame(width: 34, alignment: .trailing)

            Text(Fmt.compact(item.memory))
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 15)
    }

    /// 颜色按「占整机多少」判断，而不是按「吃了几个核」。
    ///
    /// 这里之前是错的：只要 ≥100% 就标红。但 100% 只是「吃满一个核心」，
    /// 在 10 核机器上仅占整机 10%，属于正常现象——把正常的并行计算标成
    /// 危险，会让用户误以为出了故障。
    private func processCPUColor(_ cpu: Double) -> Color {
        let cores = max(1.0, Double(store.cpu.coreCount))
        let share = cpu / cores
        if share >= 0.6 { return Palette.danger.opacity(0.9) }
        if share >= 0.3 { return Palette.warn.opacity(0.9) }
        return .white.opacity(0.62)
    }

    // MARK: - 辅助

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .kerning(0.8)
        }
        .foregroundStyle(.white.opacity(0.38))
    }

    private func ratio(_ part: UInt64, of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return Double(part) / Double(total)
    }

    /// 交换分区的告警档位。
    /// 实测：系统会预先建好 swap 文件，用掉几百 KB 是常态，
    /// 所以不能「非 0 就报警」——那会天天亮黄灯，最后就没人看了。
    /// 0：无告警；1：≥256 MB；2：≥1 GB
    private func swapSeverity(_ memory: MemorySnapshot) -> Int {
        if memory.swapUsed >= 1_073_741_824 { return 2 }
        if memory.swapUsed >= 268_435_456 { return 1 }
        return 0
    }

    private var warningColor: Color? {
        let memory = store.memory
        let severity = swapSeverity(memory)
        if memory.pressure == .critical || severity == 2 { return Palette.danger }
        if memory.pressure == .warning || severity == 1 { return Palette.warn }
        return nil
    }

    private func swapIndicator(_ memory: MemorySnapshot) -> some View {
        let severity = swapSeverity(memory)
        let active = severity > 0
        let color: Color = severity == 2 ? Palette.danger
            : (severity == 1 ? Palette.warn : .white.opacity(0.35))

        return HStack(spacing: 4) {
            // 圆点位置常驻，避免告警出现时整行跳动
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
                .opacity(active ? 1 : 0)

            Text("交换")
                .foregroundStyle(active ? color.opacity(0.95) : .white.opacity(0.35))

            Text(swapText(memory))
                .foregroundStyle(active ? color : .white.opacity(0.62))
                .monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .help(swapHelp(memory))
    }

    /// 只显示「已经用了多少」，不显示总量。
    ///
    /// 总量是系统**当前已经创建出来的交换文件容量**，不够时会自动再加，
    /// 既不是上限也不是建议值。写成「已用 / 总量」会让人误以为快满了，
    /// 所以只留已用量，总量放进悬停提示里。
    private func swapHelp(_ memory: MemorySnapshot) -> String {
        let allocated = Fmt.size(memory.swapTotal)
        return "交换 = 内存不够时，把东西临时搬到硬盘上（搬回来很慢，所以这时候会卡）。"
            + "现在是已用 \(Fmt.size(memory.swapUsed))，系统已分配 \(allocated)。"
            + "这个分配量不是上限，也不代表你只能用到这么多——不够时系统会自动再建交换文件，"
            + "真正的上限是磁盘剩余空间。超过 256 MB 转黄、超过 1 GB 转红。"
    }

    private func swapText(_ memory: MemorySnapshot) -> String {
        guard memory.swapUsed > 0 else { return "未启用" }
        return Fmt.compact(memory.swapUsed)
    }
}
