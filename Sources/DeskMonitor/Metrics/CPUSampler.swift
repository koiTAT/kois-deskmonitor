import Darwin
import Foundation

/// 通过 `host_processor_info` 读取每个逻辑核的 tick 计数，差分后得到占用率。
///
/// 注意：tick 是 UInt32，长时间运行会回绕，所以差值必须用 `&-`（wrapping）。
final class CPUSampler {
    private var previous: [UInt32] = []

    func sample() -> CPUSnapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let info, cpuCount > 0 else {
            return CPUSnapshot()
        }

        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let loads = info.withMemoryRebound(
            to: processor_cpu_load_info.self,
            capacity: Int(cpuCount)
        ) { pointer -> [processor_cpu_load_info] in
            Array(UnsafeBufferPointer(start: pointer, count: Int(cpuCount)))
        }

        // 展平成 [user, system, idle, nice] × n
        var current = [UInt32](repeating: 0, count: Int(cpuCount) * 4)
        for index in 0..<Int(cpuCount) {
            let ticks = loads[index].cpu_ticks
            let base = index * 4
            current[base] = ticks.0      // CPU_STATE_USER
            current[base + 1] = ticks.1  // CPU_STATE_SYSTEM
            current[base + 2] = ticks.2  // CPU_STATE_IDLE
            current[base + 3] = ticks.3  // CPU_STATE_NICE
        }

        // 第一次采样没有基准，只记录，返回空值
        guard previous.count == current.count else {
            previous = current
            return CPUSnapshot(
                totalUsage: 0,
                user: 0,
                system: 0,
                idle: 1,
                perCore: Array(repeating: 0, count: Int(cpuCount))
            )
        }

        var perCore = [Double]()
        perCore.reserveCapacity(Int(cpuCount))
        var sumUser = 0.0
        var sumSystem = 0.0
        var sumIdle = 0.0

        for index in 0..<Int(cpuCount) {
            let base = index * 4
            let deltaUser = Double(current[base] &- previous[base]) + Double(current[base + 3] &- previous[base + 3])
            let deltaSystem = Double(current[base + 1] &- previous[base + 1])
            let deltaIdle = Double(current[base + 2] &- previous[base + 2])
            let busy = deltaUser + deltaSystem
            let total = busy + deltaIdle

            perCore.append(total > 0 ? min(1, busy / total) : 0)
            sumUser += deltaUser
            sumSystem += deltaSystem
            sumIdle += deltaIdle
        }

        previous = current

        let totalTicks = sumUser + sumSystem + sumIdle
        guard totalTicks > 0 else {
            return CPUSnapshot(perCore: perCore)
        }

        return CPUSnapshot(
            totalUsage: min(1, (sumUser + sumSystem) / totalTicks),
            user: sumUser / totalTicks,
            system: sumSystem / totalTicks,
            idle: sumIdle / totalTicks,
            perCore: perCore
        )
    }
}
