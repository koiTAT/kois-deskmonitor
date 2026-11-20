import Foundation

/// Watches the snapshot file the DSH host plugin writes and publishes decoded
/// progress on the main thread.
///
/// The file is replaced atomically (write to a temp name, then rename), so the
/// directory is watched rather than the file: a rename changes the inode and a
/// file-descriptor watch would go deaf after the first update. A slow poll runs
/// alongside as a safety net for missed events.
public final class SnapshotStore {
    /// The last successfully decoded document, if any.
    public private(set) var snapshot: ProgressSnapshot?
    /// Why the last read produced no document, when it failed.
    public private(set) var failure: String?
    /// When the current document was read.
    public private(set) var readAt: Date?

    /// The file DSH writes, overrideable for tests and for a second profile.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["DSH_TASKS_SNAPSHOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/state/workspace-progress.json")
    }

    private let url: URL
    private let queue = DispatchQueue(label: "dsh.tasks.snapshot", qos: .utility)
    private var directoryFD: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var started = false
    /// One entry per consumer (status item, panel model); each is called on main.
    private var observers: [UUID: (ProgressSnapshot?) -> Void] = [:]

    public init(url: URL = SnapshotStore.defaultURL) {
        self.url = url
    }

    /// Register a main-thread observer.
    /// - Parameter observer: receives the decoded document, or the last good one on a read failure.
    /// - Returns: the deregistration closure.
    @discardableResult
    public func addObserver(_ observer: @escaping (ProgressSnapshot?) -> Void) -> () -> Void {
        let token = UUID()
        observers[token] = observer
        return { [weak self] in self?.observers[token] = nil }
    }

    deinit { stop() }

    /// Begin watching. Safe to call once; repeated calls are ignored.
    public func start() {
        guard !started else { return }
        started = true
        watchDirectory()
        reload()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Stop watching and release the directory descriptor.
    public func stop() {
        poll?.invalidate()
        poll = nil
        source?.cancel()
        source = nil
        if directoryFD >= 0 {
            close(directoryFD)
            directoryFD = -1
        }
    }

    /// Read and decode once, then notify on the main thread.
    public func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<ProgressSnapshot, Error>
            do {
                let data = try Data(contentsOf: self.url)
                let decoder = JSONDecoder()
                result = .success(try decoder.decode(ProgressSnapshot.self, from: data))
            } catch let error as DecodingError {
                result = .failure(SnapshotError.malformed(self.url, String(describing: error)))
            } catch {
                result = .failure(SnapshotError.missing(self.url))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let document):
                    self.snapshot = document
                    self.failure = nil
                case .failure(let error):
                    self.failure = (error as? SnapshotError)?.description ?? String(describing: error)
                    // Keep the last good document so a transient write gap does
                    // not blank the menu bar.
                }
                self.readAt = Date()
                for observer in self.observers.values {
                    observer(self.snapshot)
                }
            }
        }
    }

    /// Open the containing directory and watch it for any change.
    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A replaced directory invalidates the descriptor; re-arm it.
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.source?.cancel()
                self.source = nil
                if self.directoryFD >= 0 { close(self.directoryFD) }
                self.directoryFD = -1
                self.watchDirectory()
            }
            self.reload()
        }
        source.resume()
        self.source = source
    }
}
