import Darwin
import Foundation
import IOKit

// MARK: - 网络

struct NetworkSnapshot: Equatable {
    var downPerSecond: Double = 0
    var upPerSecond: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
}

/// 用 `NET_RT_IFLIST2` 读 64 位网卡计数器。
///
/// 只用 `if_data`（32 位）会在几十 GB 流量后回绕，所以必须走 `if_data64`。
/// 只统计 `en*` / `pdp_ip*`，否则 VPN（utun）会和物理网卡重复计数。
final class NetworkSampler {
    private var previousDown: UInt64 = 0
    private var previousUp: UInt64 = 0
    private var previousTime: TimeInterval = 0

    func sample() -> NetworkSnapshot {
        let (down, up) = Self.counters()
        let now = ProcessInfo.processInfo.systemUptime

        var snapshot = NetworkSnapshot(totalDown: down, totalUp: up)
        if previousTime > 0 {
            let elapsed = max(0.001, now - previousTime)
            snapshot.downPerSecond = Double(Self.delta(down, previousDown)) / elapsed
            snapshot.upPerSecond = Double(Self.delta(up, previousUp)) / elapsed
        }

        previousDown = down
        previousUp = up
        previousTime = now
        return snapshot
    }

    /// 实测发现：本机内核对 en1 只填了 `ifi_ibytes` 的低 32 位
    /// （netstat 显示 21.9 GB，`NET_RT_IFLIST2` 读出来是 21.9GB mod 2^32）。
    /// C 和 Swift 结果一致，确认是内核侧行为，不是绑定问题。
    ///
    /// 所以差值必须按 32 位回绕来算：直接做 64 位减法，计数器每翻转一次
    /// （高速下载时几十秒一次）就会飙出一个天文数字的速率尖峰。
    /// 取低 32 位对真实 64 位计数器同样安全——1 秒内不可能流过 4 GB。
    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        (current &- previous) & 0xFFFF_FFFF
    }

    private static func counters() -> (down: UInt64, up: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var totalDown: UInt64 = 0
        var totalUp: UInt64 = 0

        buffer.withUnsafeMutableBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            let end = pointer.advanced(by: raw.count)

            while pointer < end {
                let header = pointer.assumingMemoryBound(to: if_msghdr2.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    var nameBuffer = [CChar](repeating: 0, count: 32)
                    if if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil {
                        let name = String(
                            decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                            as: UTF8.self
                        )
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            totalDown &+= header.ifm_data.ifi_ibytes
                            totalUp &+= header.ifm_data.ifi_obytes
                        }
                    }
                }

                pointer = pointer.advanced(by: messageLength)
            }
        }

        return (totalDown, totalUp)
    }
}

// MARK: - 磁盘

struct DiskSnapshot: Equatable {
    var readPerSecond: Double = 0
    var writePerSecond: Double = 0
    var capacity: UInt64 = 0
    var available: UInt64 = 0
}

/// 容量用 `statfs`，读写速率用 IOKit 的 `IOBlockStorageDriver` 累计字节差分。
final class DiskSampler {
    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var previousTime: TimeInterval = 0

    func sample() -> DiskSnapshot {
        var snapshot = DiskSnapshot()
        let capacity = Self.capacity()
        snapshot.capacity = capacity.total
        snapshot.available = capacity.available

        let (read, write) = Self.ioCounters()
        let now = ProcessInfo.processInfo.systemUptime

        if previousTime > 0 {
            let elapsed = max(0.001, now - previousTime)
            snapshot.readPerSecond = Double(read &- previousRead) / elapsed
            snapshot.writePerSecond = Double(write &- previousWrite) / elapsed
        }

        previousRead = read
        previousWrite = write
        previousTime = now
        return snapshot
    }

    private static func capacity() -> (total: UInt64, available: UInt64) {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return (0, 0) }
        let blockSize = UInt64(stats.f_bsize)
        return (UInt64(stats.f_blocks) * blockSize, UInt64(stats.f_bavail) * blockSize)
    }

    private static func ioCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                entry,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
        }

        return (read, write)
    }
}

// MARK: - GPU

struct GPUSnapshot: Equatable {
    var utilization: Double = 0
    var available: Bool = false
}

/// Apple Silicon 上不用 root 就能从 `IOAccelerator` 读到 GPU 占用率。
/// `Device Utilization %` 是整卡占用，取所有加速器里的最大值。
final class GPUSampler {
    func sample() -> GPUSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return GPUSnapshot()
        }
        defer { IOObjectRelease(iterator) }

        var best = 0
        var found = false

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                entry,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
                let utilization = stats["Device Utilization %"] as? NSNumber {
                found = true
                best = max(best, utilization.intValue)
            }
            IOObjectRelease(entry)
        }

        return GPUSnapshot(
            utilization: Double(min(100, max(0, best))) / 100,
            available: found
        )
    }
}
