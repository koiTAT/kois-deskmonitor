import AppKit
import DSHTasksKit
import SwiftUI

/// 离屏渲染界面预览图。
///
/// 用途：
///   1. 无法截屏（没给录屏权限）时验证 UI；
///   2. 将来做 App Store 截图，直接批量出图，不用手动摆窗口。
///
/// 用法：`DeskMonitor --render <输出路径.png> [--hero] [采样秒数]`
@MainActor
enum PreviewRenderer {
    static func run(outputPath: String, hero: Bool = false, demoWarning: Bool = false, compact: Bool = false, minimal: Bool = false, withWeather: Bool = false, withTasks: Bool = false, duration: TimeInterval = 12) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let store = MetricsStore()
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let network = NetworkSampler()
        let disk = DiskSampler()
        let gpu = GPUSampler()
        let processes = ProcessSampler()

        store.showProcesses = true
        _ = processes.sample()  // 建立进程 CPU 时间基准

        // 建立 CPU tick 与网卡/磁盘累计字节的基准
        _ = cpu.sample()
        _ = network.sample()
        _ = disk.sample()

        let steps = max(8, Int(duration / 0.1))
        for _ in 0..<steps {
            Thread.sleep(forTimeInterval: 0.1)
            // run() 已是 @MainActor，直接调用即可。
            // 注意：在主线程上 DispatchQueue.main.sync 会直接死锁崩溃。
            store.apply(
                SampleBundle(
                    cpu: cpu.sample(),
                    memory: memory.sample(),
                    network: network.sample(),
                    disk: disk.sample(),
                    gpu: gpu.sample()
                )
            )
        }

        store.apply(processes: processes.sample())

        if withWeather {
            store.weather = fetchWeather()
        }

        if minimal {
            store.compactMode = true
        }

        if compact {
            // 预览「只留 CPU + 内存」的最小面板
            store.showNetwork = false
            store.showDisk = false
            store.showGPU = false
            store.showProcesses = false
        }

        if demoWarning {
            // 演示用：伪造内存告警状态，方便检查配色
            store.memory.swapUsed = 2_400_000_000
            store.memory.swapTotal = 4_000_000_000
            store.memory.pressure = .warning
        }

        // DSH 任务卡片要等一次异步读盘，转几圈 runloop 让它落到 @Published 上
        var taskMonitor: TaskMonitor?
        if withTasks {
            let monitor = TaskMonitor()
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            taskMonitor = monitor
        }

        // 不要在这里固定宽度：视图自己会根据 compactMode 决定 210 / 296，
        // 外面再套一层 .frame(width:) 会把它覆盖掉，预览就骗人了。
        let view = MonitorView(store: store, useVibrancy: false, interactive: false, taskMonitor: taskMonitor)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            fail("渲染失败")
        }

        let output = hero ? composite(image) : image
        guard let final = output else { fail("合成失败") }

        guard let tiff = final.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            fail("编码 PNG 失败")
        }

        let url = URL(fileURLWithPath: outputPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: url)
            print("✅ 预览图: \(url.path)  (\(Int(final.size.width))×\(Int(final.size.height)) pt)")
        } catch {
            fail("写入失败: \(error)")
        }
    }

    /// 同步拉一次天气，仅用于预览出图
    private static func fetchWeather() -> WeatherSnapshot {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double?
                let weather_code: Int?
            }
            let current: Current?
        }

        var snapshot = WeatherSnapshot(cityName: "上海")
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: "31.2304"),
            URLQueryItem(name: "longitude", value: "121.4737"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let current = decoded.current
        else { return snapshot }

        snapshot.temperature = current.temperature_2m
        snapshot.weatherCode = current.weather_code
        snapshot.symbolName = WeatherService.symbol(for: current.weather_code)
        snapshot.condition = WeatherService.condition(for: current.weather_code)
        snapshot.updatedAt = Date()
        return snapshot
    }

    /// 把面板贴到一张渐变"桌面"上，带投影，用于展示悬浮效果
    private static func composite(_ panel: NSImage) -> NSImage? {
        let canvasSize = NSSize(width: 640, height: 470)
        let canvas = NSImage(size: canvasSize)

        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: canvasSize)
        if let gradient = NSGradient(colors: [
            NSColor(red: 0.16, green: 0.18, blue: 0.28, alpha: 1),
            NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1),
        ]) {
            gradient.draw(in: bounds, angle: -60)
        }

        let size = panel.size
        let target = NSRect(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        NSGraphicsContext.current?.imageInterpolation = .high
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        panel.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()

        return canvas
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
