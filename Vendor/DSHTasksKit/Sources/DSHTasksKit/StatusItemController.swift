import AppKit
import Foundation

/// Owns one `NSStatusItem` that summarises the workspace plan.
///
/// The item is hidden while there is nothing to show, so it costs no menu bar
/// space when DSH is idle or closed. Clicking it opens a menu listing every
/// tracked session and its checklist.
///
/// AppKit calls stay on the main thread: the snapshot callback hops to main
/// before rendering, and the app delegates that drive it run on the main thread.
public final class StatusItemController: NSObject {
    /// Focus the DSH window.
    public var onOpen: (() -> Void)?
    /// Quit the owning app, used by the standalone shell only.
    public var onQuit: (() -> Void)?

    /// Whether the item may appear at all.
    public var isEnabled = true {
        didSet { render() }
    }

    /// Whether the task name follows the fraction in the menu bar.
    public var showsTaskName = true {
        didSet { render() }
    }

    private let store: SnapshotStore
    private let item: NSStatusItem
    private var monitor: TaskMonitor?

    /// - Parameters:
    ///   - store: the snapshot source, already started by the caller.
    ///   - order: position hint; only used for the initial length.
    public init(store: SnapshotStore, order: Int = 0) {
        self.store = store
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        self.item.autosaveName = "dsh.tasks.\(order)"
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        }
        store.addObserver { [weak self] _ in
            self?.render()
        }
        render()
    }

    deinit {
        // The item dies with the process; nothing to release explicitly.
    }

    /// Rebuild the item and its menu from the current snapshot.
    public func render() {
        guard isEnabled, let snapshot = store.snapshot, snapshot.overall.total > 0 else {
            item.isVisible = false
            item.menu = nil
            if ProcessInfo.processInfo.environment["DSH_TASKS_DEBUG"] != nil {
                let line = "DSHTasks render visible=false snapshot=\(store.snapshot == nil ? "nil" : "empty")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            return
        }
        item.isVisible = true

        let focused = snapshot.focusedSession
        let attention = focused?.isWaiting ?? false
        let active = focused?.isRunning ?? false
        let progress = focused?.progress ?? (snapshot.overall.total == 0
            ? 0
            : Double(snapshot.overall.completed) / Double(snapshot.overall.total))
        item.button?.image = TaskRing.image(for: .init(progress: progress, attention: attention, active: active))
        item.button?.title = titleText(for: snapshot)
        item.button?.toolTip = tooltipText(for: snapshot)
        item.menu = buildMenu(for: snapshot)

        if ProcessInfo.processInfo.environment["DSH_TASKS_DEBUG"] != nil {
            let line = "DSHTasks render visible=true title=\"\(titleText(for: snapshot))\" sessions=\(snapshot.sessions.count)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private func titleText(for snapshot: ProgressSnapshot) -> String {
        guard let focused = snapshot.focusedSession else { return "" }

        // 没有清单：只报「在跑 / 等确认」
        if focused.total == 0 {
            return focused.isWaiting ? " 等确认" : " 运行中"
        }

        let fraction = "\(focused.counts.completed)/\(focused.total)"
        // 等确认比「做到哪一步」更急，直接用状态词占住文字位
        if focused.isWaiting { return " \(fraction) 等确认" }
        guard showsTaskName else { return " \(fraction)" }
        guard let task = focused.activeTodo?.content ?? focused.nextTodo?.content else {
            // 清单全打勾但还在跑，别让状态项看起来像结束了
            return focused.isRunning ? " \(fraction) 运行中" : " \(fraction)"
        }
        return " \(fraction) \(ProgressSnapshot.truncate(task, limit: 12))"
    }

    private func tooltipText(for snapshot: ProgressSnapshot) -> String {
        guard let focused = snapshot.focusedSession else { return "DSH 工作区任务" }
        var lines = ["DSH · \(snapshot.workspace.name ?? "工作区")"]
        if focused.total == 0 {
            lines.append("\(focused.title)：\(focused.isWaiting ? "等待确认" : "运行中")")
        } else {
            lines.append("\(focused.title)：\(focused.counts.completed)/\(focused.total)")
        }
        if let task = focused.activeTodo?.content ?? focused.nextTodo?.content {
            lines.append("进行中：\(task)")
        }
        if snapshot.overall.sessions > 1 {
            lines.append("共 \(snapshot.overall.sessions) 个会话有任务")
        }
        return lines.joined(separator: "\n")
    }

    private func buildMenu(for snapshot: ProgressSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let heading = NSMenuItem(
            title: snapshot.workspace.name.map { "工作区 · \($0)" } ?? "DSH 工作区",
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        for session in snapshot.sessions {
            let prefix = session.total == 0
                ? (session.isWaiting ? "等确认" : "运行中")
                : "\(session.counts.completed)/\(session.total)"
            let row = NSMenuItem(title: "\(prefix)  \(session.title)", action: nil, keyEquivalent: "")
            row.image = TaskRing.image(for: .init(
                progress: session.progress,
                attention: session.isWaiting,
                active: session.isRunning,
                size: 14
            ))
            row.submenu = sessionMenu(for: session)
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 DSH", action: #selector(openApp), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let nameToggle = NSMenuItem(title: "显示任务名", action: #selector(toggleName), keyEquivalent: "")
        nameToggle.target = self
        nameToggle.state = showsTaskName ? .on : .off
        menu.addItem(nameToggle)

        let hide = NSMenuItem(title: "暂时隐藏", action: #selector(toggleVisible), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        if onQuit != nil {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }
        return menu
    }

    private func sessionMenu(for session: ProgressSnapshot.Session) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for todo in session.todos {
            let row = NSMenuItem(title: todo.content, action: nil, keyEquivalent: "")
            row.state = todo.isCompleted ? .on : .off
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 DSH", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func openApp() {
        onOpen?()
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func toggleName() {
        showsTaskName.toggle()
    }

    @objc private func toggleVisible() {
        isEnabled = false
    }
}

/// Observable adapter so SwiftUI clients (the DeskMonitor panel) can bind to the
/// store without knowing about its manual change callback.
public final class TaskMonitor: ObservableObject {
    @Published public private(set) var snapshot: ProgressSnapshot?
    @Published public private(set) var failure: String?
    public let store: SnapshotStore

    public init(url: URL = SnapshotStore.defaultURL) {
        store = SnapshotStore(url: url)
        store.addObserver { [weak self] snapshot in
            self?.snapshot = snapshot
            self?.failure = snapshot == nil ? self?.store.failure : nil
        }
        store.start()
    }
}
