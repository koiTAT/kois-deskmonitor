import AppKit
import Darwin
import Foundation

// MARK: - 单个 App 的占用
struct ProcessUsage: Identifiable {
    /// 用 App 主进程 pid 作为稳定标识
    let id: pid_t
    let name: String
    /// 1.0 = 吃满一个核心；多线程 App 会超过 100%
    let cpu: Double
    /// 该 App 所有进程 RSS 之和
    let memory: UInt64
    /// 归并进来的进程数量（主进程 + 各种 Helper）
    let processCount: Int
    let icon: NSImage?
}

// MARK: - 进程采样
//
/// 两个关键实现细节，都是实测踩出来的：
///
/// 1. **单位**：`proc_taskinfo.pti_total_user/system` 的单位是 **mach 绝对时钟 tick**，
///    不是纳秒。Apple Silicon 上是 24 MHz，必须用 `mach_timebase_info` 换算。
///    直接当纳秒用会把 CPU 低估约 41.7 倍（实测：满载 2 秒 = 46,568,981 tick）。
///
/// 2. **口径**：只统计主进程是错的。Chrome/Edge/网易云/VSCode 的负载几乎
///    全在 Helper 子进程里，主进程常年 0%。所以这里枚举全部 pid，
///    按「可执行文件路径是否落在某个 .app 包里」归并到对应 App。
///
/// 沙盒下 `proc_pidpath` / `proc_pidinfo` 会返回 EPERM，
/// 这个模块整体失效——所以它是可开关的可选项。
final class ProcessSampler {
    private var previousTicks: [pid_t: UInt64] = [:]
    private var previousTime: TimeInterval = 0
    private var iconCache: [String: NSImage] = [:]
    private let timebase: mach_timebase_info_data_t
    private let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    func sample(limit: Int = 5) -> [ProcessUsage] {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime > 0 ? max(0.05, now - previousTime) : 0

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier > 1
        }
        let owners: [(path: String, app: NSRunningApplication)] = apps.compactMap { app in
            guard let path = app.bundleURL?.standardizedFileURL.path else { return nil }
            return (path, app)
        }

        var buckets: [pid_t: Bucket] = [:]
        var nextTicks: [pid_t: UInt64] = [:]

        var pids = [pid_t](repeating: 0, count: 8192)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let pidCount = proc_listallpids(&pids, capacity)

        for index in 0..<max(0, Int(pidCount)) {
            let pid = pids[index]
            guard pid > 1 else { continue }

            let executablePath = self.executablePath(of: pid)
            guard !executablePath.isEmpty,
                  let owner = owners.first(where: { executablePath.hasPrefix($0.path + "/") })
            else { continue }

            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else {
                continue
            }

            let total = info.pti_total_user &+ info.pti_total_system
            nextTicks[pid] = total

            var pending = buckets[owner.app.processIdentifier]
                ?? Bucket(app: owner.app, bundlePath: owner.path)
            pending.memory &+= info.pti_resident_size
            pending.processCount += 1
            if let last = previousTicks[pid], elapsed > 0 {
                pending.cpuSeconds += seconds(fromTicks: total &- last)
            }
            buckets[owner.app.processIdentifier] = pending
        }

        previousTicks = nextTicks
        previousTime = now

        let results: [ProcessUsage] = buckets.values.map { bucket in
            ProcessUsage(
                id: bucket.app.processIdentifier,
                name: bucket.app.localizedName ?? bucket.bundlePath,
                cpu: elapsed > 0 ? bucket.cpuSeconds / elapsed : 0,
                memory: bucket.memory,
                processCount: bucket.processCount,
                icon: icon(for: bucket)
            )
        }

        // 首帧全是 0，按内存排序更直观
        if results.allSatisfy({ $0.cpu < 0.005 }) {
            return Array(results.sorted { $0.memory > $1.memory }.prefix(limit))
        }
        return Array(results.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }

    // MARK: - 内部

    private struct Bucket {
        let app: NSRunningApplication
        let bundlePath: String
        var cpuSeconds: Double = 0
        var memory: UInt64 = 0
        var processCount: Int = 0
    }

    private func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private func icon(for bucket: Bucket) -> NSImage? {
        if let cached = iconCache[bucket.bundlePath] {
            return cached
        }
        guard let icon = bucket.app.icon else { return nil }
        iconCache[bucket.bundlePath] = icon
        return icon
    }
}
