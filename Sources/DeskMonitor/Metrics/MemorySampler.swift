import Darwin
import Foundation

/// 读取内存总量、分类占用、Swap 与内存压力。
///
/// 口径参考「活动监视器」：
///   - 应用内存 = internal_page_count - purgeable_count
///   - 联动内存 = wire_count
///   - 压缩内存 = compressor_page_count
///   - 文件缓存 = external_page_count + purgeable_count
final class MemorySampler {
    private let pageSize: UInt64 = UInt64(vm_kernel_page_size)

    /// 与内核 `struct xsw_usage` 二进制布局一致
    private struct SwapUsage {
        var total: UInt64 = 0
        var available: UInt64 = 0
        var used: UInt64 = 0
        var pageSize: UInt32 = 0
        var encrypted: UInt32 = 0
    }

    func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = ProcessInfo.processInfo.physicalMemory
        snapshot.pressure = readPressure()
        readSwap(into: &snapshot)
        readPages(into: &snapshot)
        return snapshot
    }

    // MARK: - 页统计

    private func readPages(into snapshot: inout MemorySnapshot) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        func bytes(_ pages: natural_t) -> UInt64 { UInt64(pages) * pageSize }

        let internalBytes = bytes(stats.internal_page_count)
        let purgeableBytes = bytes(stats.purgeable_count)
        let externalBytes = bytes(stats.external_page_count)

        snapshot.appMemory = internalBytes > purgeableBytes ? internalBytes - purgeableBytes : 0
        snapshot.wired = bytes(stats.wire_count)
        snapshot.compressed = bytes(stats.compressor_page_count)
        snapshot.cachedFiles = externalBytes &+ purgeableBytes
    }

    // MARK: - 内存压力

    private func readPressure() -> PressureLevel {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return PressureLevel(rawLevel: level)
    }

    // MARK: - Swap

    private func readSwap(into snapshot: inout MemorySnapshot) {
        var usage = SwapUsage()
        var size = MemoryLayout<SwapUsage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        snapshot.swapTotal = usage.total
        snapshot.swapUsed = usage.used
    }
}
