import AppKit
import Foundation

/// 采样耗时基准：`DeskMonitor --bench`
///
/// 用来判断「监视器自己有多重」。资源监视器如果比被监视的 App 还费 CPU，
/// 那就是产品失败，所以这个数字必须能随时量。
enum Bench {
    static func run() {
        let processSampler = ProcessSampler()
        let cpuSampler = CPUSampler()
        let memorySampler = MemorySampler()
        let networkSampler = NetworkSampler()
        let diskSampler = DiskSampler()
        let gpuSampler = GPUSampler()

        print("=== 进程采样耗时 ===")
        for index in 1...5 {
            let start = Date()
            let rows = processSampler.sample()
            let elapsed = Date().timeIntervalSince(start) * 1000
            print(String(format: "  [%d] %7.1f ms   %d 行", index, elapsed, rows.count))
            Thread.sleep(forTimeInterval: 1.5)
        }

        print("=== 系统级采样耗时 ===")

        func bench(_ name: String, _ block: () -> Void) {
            let start = Date()
            for _ in 0..<100 { block() }
            let elapsed = Date().timeIntervalSince(start) * 1000
            print(String(format: "  %-8@ %7.1f ms / 100 次  → 单次 %.2f ms", name as NSString, elapsed, elapsed / 100))
        }

        bench("CPU") { _ = cpuSampler.sample() }
        bench("内存") { _ = memorySampler.sample() }
        bench("网络") { _ = networkSampler.sample() }
        bench("磁盘") { _ = diskSampler.sample() }
        bench("GPU") { _ = gpuSampler.sample() }

        print("=== 实测读数 ===")
        let net = networkSampler.sample()
        let dsk = diskSampler.sample()
        let gpu = gpuSampler.sample()
        print("  网络: ↓ \(Fmt.rate(net.downPerSecond)) ↑ \(Fmt.rate(net.upPerSecond))")
        print("  网络累计: ibytes=\(net.totalDown) obytes=\(net.totalUp)")
        print("  磁盘: R \(Fmt.rate(dsk.readPerSecond)) W \(Fmt.rate(dsk.writePerSecond))  剩余 \(Fmt.size(dsk.available)) / \(Fmt.size(dsk.capacity))")
        print("  GPU : \(gpu.available ? Fmt.percent(gpu.utilization) : "不可用")")
    }
}
