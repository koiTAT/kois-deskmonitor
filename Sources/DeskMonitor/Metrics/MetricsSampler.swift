import Foundation

/// 一次采样得到的全部快照
struct SampleBundle {
    var cpu = CPUSnapshot()
    var memory = MemorySnapshot()
    var network = NetworkSnapshot()
    var disk = DiskSnapshot()
    var gpu = GPUSnapshot()
}

/// 后台定时采样，结果回调到主线程。
/// 采样在串行后台队列上执行，避免影响 UI 帧率。
final class MetricsSampler {
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let gpuSampler = GPUSampler()

    private let queue = DispatchQueue(label: "com.koiono.deskmonitor.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private(set) var interval: TimeInterval = 1.0

    /// 回调始终在主线程
    var onSample: ((SampleBundle) -> Void)?

    func start(interval: TimeInterval) {
        stop()
        self.interval = interval

        // 先垫一次采样，建立 CPU tick 与网卡/磁盘字节的基准，避免第一帧全是 0
        queue.async { [weak self] in
            self?.sampleOnce()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let bundle = self.sampleOnce()
            DispatchQueue.main.async {
                self.onSample?(bundle)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sampleOnce() -> SampleBundle {
        SampleBundle(
            cpu: cpuSampler.sample(),
            memory: memorySampler.sample(),
            network: networkSampler.sample(),
            disk: diskSampler.sample(),
            gpu: gpuSampler.sample()
        )
    }

    deinit {
        timer?.cancel()
    }
}
