import AppKit
import Foundation

@main
enum DeskMonitorMain {
    /// NSApplication.delegate 是弱引用，必须自己持有
    private static var appDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            let args = CommandLine.arguments
            let rawPath = args.count > index + 1 ? args[index + 1] : "preview.png"
            let path = rawPath.hasPrefix("--") ? "preview.png" : rawPath
            let hero = args.contains("--hero")
            let demoWarning = args.contains("--warn")
            let compact = args.contains("--compact")
            let minimal = args.contains("--minimal")
            let withWeather = args.contains("--weather")
            let withTasks = args.contains("--tasks")
            MainActor.assumeIsolated {
                PreviewRenderer.run(
                    outputPath: path,
                    hero: hero,
                    demoWarning: demoWarning,
                    compact: compact,
                    minimal: minimal,
                    withWeather: withWeather,
                    withTasks: withTasks
                )
            }
            return
        }

        if CommandLine.arguments.contains("--bench") {
            Bench.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - 命令行自检
//
// `DeskMonitor --probe` 不启动界面，直接把采样结果打到终端，
// 方便排查「数据不准」类问题。
enum Probe {
    static func run() {
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let network = NetworkSampler()
        let disk = DiskSampler()
        let gpu = GPUSampler()

        _ = cpu.sample()  // 建立基准
        _ = network.sample()
        _ = disk.sample()
        print("=== DeskMonitor 采样自检（5 次，间隔 0.8s）===")

        for index in 1...5 {
            Thread.sleep(forTimeInterval: 0.8)
            let cpuSnapshot = cpu.sample()
            let memorySnapshot = memory.sample()

            let cores = cpuSnapshot.perCore
                .map { String(format: "%2.0f", $0 * 100) }
                .joined(separator: " ")

            print(String(
                format: "[%d] CPU %5.1f%%  用户 %5.1f%%  系统 %5.1f%%",
                index,
                cpuSnapshot.totalUsage * 100,
                cpuSnapshot.user * 100,
                cpuSnapshot.system * 100
            ))
            print("    核心占用: [\(cores)]")
            print("    内存: \(Fmt.size(memorySnapshot.used)) / \(Fmt.size(memorySnapshot.total))"
                + "  应用 \(Fmt.size(memorySnapshot.appMemory))"
                + "  联动 \(Fmt.size(memorySnapshot.wired))"
                + "  压缩 \(Fmt.size(memorySnapshot.compressed))"
                + "  缓存 \(Fmt.size(memorySnapshot.cachedFiles))"
                + "  压力 \(memorySnapshot.pressure.label)")
            print("    交换: \(Fmt.size(memorySnapshot.swapUsed)) / \(Fmt.size(memorySnapshot.swapTotal))")
            let net = network.sample()
            let dsk = disk.sample()
            let g = gpu.sample()
            print("    网络: ↓ \(Fmt.rate(net.downPerSecond))  ↑ \(Fmt.rate(net.upPerSecond))")
            print("    磁盘: R \(Fmt.rate(dsk.readPerSecond))  W \(Fmt.rate(dsk.writePerSecond))  剩余 \(Fmt.size(dsk.available)) / \(Fmt.size(dsk.capacity))")
            print("    GPU : \(g.available ? Fmt.percent(g.utilization) : "不可用")")
        }
    }
}
