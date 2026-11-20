import AppKit
import Carbon.HIToolbox
import DSHTasksKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // 用 lazy 是为了能用 DM_BARE 精确二分「哪一步在空转」
    private lazy var store = MetricsStore()
    private lazy var sampler = MetricsSampler()
    private lazy var processSampler = ProcessSampler()
    private let weatherService = WeatherService()
    private var weatherTimer: Timer?

    private var panel: FloatingPanel!
    private var hostingView: NSHostingView<MonitorView>!
    private var statusItem: NSStatusItem!
    private var processTimer: Timer?
    private var lastStatusTitle = ""

    /// DSH 任务进度：默认跟随 ~/.dsh/state/workspace-progress.json
    private let taskMonitor = TaskMonitor()
    private var taskStatusItem: StatusItemController?

    private static let frameAutosaveName = "DeskMonitorPanel"
    private static let fallbackSize = NSSize(width: 296, height: 286)

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["DM_DEBUG_ENV"] != nil {
            FileHandle.standardError.write(Data("ENV: DM_BARE=\(env["DM_BARE"] ?? "nil") DM_NO_PANEL=\(env["DM_NO_PANEL"] ?? "nil") pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        }
        if env["DM_BARE"] != nil { return }

        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installGlobalHotKey()
        installResizeMonitor()

        if env["DM_NO_PANEL"] == nil {
            buildPanel()
        }
        if env["DM_NO_STATUS"] == nil {
            buildStatusItem()
            applyPreferences()
        }
        if env["DM_NO_TASKS"] == nil {
            buildTaskItem()
        }
        if env["DM_NO_SAMPLER"] == nil {
            startSampling()
            syncProcessSampling()
        }
        startWeather()

        // 拖拽手柄改完尺寸后，切到手动高度模式并记住
        NotificationCenter.default.addObserver(
            forName: .dmManualResize, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            self.store.manualHeight = true
            self.store.panelHeight = Double(panel.frame.height)
            self.store.panelWidthPoints = Double(panel.frame.width)
            UserDefaults.standard.set(self.store.panelWidthPoints, forKey: Prefs.panelWidth)
            UserDefaults.standard.set(true, forKey: Prefs.manualHeight)
            UserDefaults.standard.set(self.store.panelHeight, forKey: Prefs.panelHeight)
            panel.saveFrame(usingName: Self.frameAutosaveName)
        }

        NotificationCenter.default.addObserver(
            forName: .dmResizeBegan, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isUserResizing = true
        }
        NotificationCenter.default.addObserver(
            forName: .dmResizeEnded, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            self.isUserResizing = false
            self.store.manualHeight = true
            self.store.panelHeight = Double(panel.frame.height)
            self.store.panelWidthPoints = Double(panel.frame.width)
            UserDefaults.standard.set(true, forKey: Prefs.manualHeight)
            UserDefaults.standard.set(self.store.panelHeight, forKey: Prefs.panelHeight)
            UserDefaults.standard.set(self.store.panelWidthPoints, forKey: Prefs.panelWidth)
            panel.saveFrame(usingName: Self.frameAutosaveName)
        }

        // 双击面板 = 一键切换简约 / 完整
        NotificationCenter.default.addObserver(
            forName: .dmToggleCompact,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleCompact()
        }

        // 换了显示器、改了分辨率，窗口可能落到新屏幕之外
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.ensureOnScreen() }
        }

        // 进程列表若在启动时就是开着的，窗口高度要补一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.resizeRecordingArmed = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.resizePanelToFit()
            if self.store.manualHeight, let panel = self.panel {
                var frame = panel.frame
                frame.size.height = max(160, CGFloat(self.store.panelHeight))
                frame.origin.y = frame.maxY - frame.size.height
                self.isApplyingFrame = true
                panel.setFrame(self.clampToScreen(frame), display: true)
                self.isApplyingFrame = false
            }
        }

        if env["DM_DUMP_MENU"] != nil {
            FileHandle.standardError.write(Data("DUMP: 开始构建菜单\n".utf8))
            let m = buildMenu()
            FileHandle.standardError.write(Data("DUMP: 构建完成\n".utf8))
            dumpMenu(m, indent: "  ")
            NSApp.terminate(nil)
            return
        }

        // 调试用：N 秒后自动切换简约/完整，用于验证切换后仍留在屏幕内
        if let raw = env["DM_TOGGLE_COMPACT_AFTER"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.toggleCompact()
            }
        }
        if let raw = env["DM_DUMP_FRAME_AFTER"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let panel = self.panel, let screen = panel.screen ?? NSScreen.main else { return }
                let f = panel.frame
                let v = screen.visibleFrame
                let fitsX = f.minX >= v.minX - 1 && f.maxX <= v.maxX + 1
                let fitsY = f.minY >= v.minY - 1 && f.maxY <= v.maxY + 1
                let onScreen = fitsX && fitsY
                let compact = self.store.compactMode
                let message = "FRAME compact=\(compact) size=\(Int(f.width))x\(Int(f.height)) origin=(\(Int(f.minX)),\(Int(f.minY))) maxX=\(Int(f.maxX)) visibleMaxX=\(Int(v.maxX)) onScreen=\(onScreen)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }

        // 调试用：把窗口丢到屏幕外，验证能不能自己回来
        if env["DM_TEST_OFFSCREEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panel.setFrameOrigin(NSPoint(x: 6000, y: 4000))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 面板

    private func buildPanel() {
        let env = ProcessInfo.processInfo.environment
        hostingView = NSHostingView(
            rootView: MonitorView(
                store: store,
                useVibrancy: env["DM_NO_VIBRANCY"] == nil,
                taskMonitor: taskMonitor
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        // 注意：这里不能再把 sizingOptions 关掉。
        // 关掉后 hostingView.fittingSize 不再反映真实内容尺寸，
        // 窗口会算错宽高并裁掉内容（圆角也会被切掉）。
        // 手动高度改为「布局后修正」，见 resizePanelToFit。

        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.fallbackSize))
        panel.delegate = self
        if env["DM_NO_SHADOW"] != nil {
            panel.hasShadow = false
        }
        panel.contentView = hostingView
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        // 注意：不能只依赖 `setFrameUsingName` 之后再判断。
        // AppKit 恢复时会把越界的 frame **自己清洗**成一个合法但随机的位置
        // （实测存 (9999,9999) 会变成 (1039,24)），因此事后检查永远是"合法"的。
        // 必须先把存储值读出来自己验一遍，不合法就干脆不恢复。
        if store.rememberFrame, savedFrameIsUsable() {
            _ = panel.setFrameUsingName(Self.frameAutosaveName)
        } else {
            moveToDefaultPosition()
        }
        if ProcessInfo.processInfo.environment["DM_DEBUG_FRAME"] != nil {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            FileHandle.standardError.write(Data(
                "FRAME savedUsable=\(savedFrameIsUsable()) now=\(panel.frame) visible=\(visible)\n".utf8))
        }

        // 让 SwiftUI 自己决定高度，避免写死尺寸导致裁切
        DispatchQueue.main.async { [weak self] in
            self?.resizePanelToFit()
        }

        panel.orderFrontRegardless()
    }

    /// 自己解析自动保存的 frame 字符串再判断，绕开 AppKit 的自动清洗。
    /// 格式："x y w h screenX screenY screenW screenH"（屏幕坐标系，原点在左下）
    private func savedFrameIsUsable() -> Bool {
        let key = "NSWindow Frame \(Self.frameAutosaveName)"
        guard let raw = UserDefaults.standard.string(forKey: key) else { return false }
        let numbers = raw.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4 else { return false }
        let frame = NSRect(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2],
            height: numbers[3]
        )
        return isFrameUsable(frame)
    }

    /// 恢复的窗口位置可能在屏幕外（换过显示器、或高度变化把原点推成负数）
    private func isFrameUsable(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let visible = screen.visibleFrame
        let intersection = frame.intersection(visible)
        // 至少要有 60pt 高度露在屏幕里，否则认为不可用
        return intersection.height >= 60 && intersection.width > 40
    }

    // MARK: - 防止窗口跑出屏幕

    /// 拖动结束后做一次检查。
    /// 拖动过程中不干预（否则会和用户的手抢方向），松手后 0.25 秒再校正。
    /// 布局变化前记录的位置锚点：贴哪一侧、离边缘多远、顶边在哪。
    /// 记录在“变化之前”，因为 AppKit 会先把窗口按自己的方式撑大，
    /// 等我们拿到 frame 时原始位置已经丢了。
    private struct PanelAnchor {
        let isRight: Bool
        let gap: CGFloat
        let top: CGFloat
    }

    private var pendingAnchor: PanelAnchor?
    private var isApplyingFrame = false
    private var isUserResizing = false
    private var resizeRecordingArmed = false
    private var weatherRetryCount = 0

    private func captureAnchor() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let leftGap = frame.minX - visible.minX
        let rightGap = visible.maxX - frame.maxX
        pendingAnchor = PanelAnchor(
            isRight: rightGap <= leftGap,
            gap: min(leftGap, rightGap),
            top: frame.maxY
        )
    }

    func windowDidMove(_ notification: Notification) {
        updateSnapPreview()
        scheduleScreenCheck()
    }

    /// 拖动过程中：靠近吸附目标时给面板描边，让用户知道松手会贴上去
    private var snapPreviewOn = false

    private func scheduleSnapPreviewClear() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearSnapPreviewObjC), object: nil)
        perform(#selector(clearSnapPreviewObjC), with: nil, afterDelay: 0.6)
    }

    @objc private func clearSnapPreviewObjC() {
        clearSnapPreview()
    }

    private func updateSnapPreview() {
        guard store.snapToDSH, !store.compactMode, let panel, let hosting = hostingView else {
            hostingView?.layer?.borderWidth = 0
            return
        }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let target = frontmostDSWindowFrame() ?? visible
        let frame = panel.frame
        let threshold: CGFloat = 12

        let nearX = [target.minX, target.maxX - frame.width,
                     visible.minX, visible.maxX - frame.width]
            .contains { abs(frame.minX - $0) <= threshold }
        let nearY = [target.minY, target.maxY,
                     visible.minY, visible.maxY - frame.height]
            .contains { abs(frame.minY - $0) <= threshold }
        let near = nearX || nearY

        guard near != snapPreviewOn else { return }
        snapPreviewOn = near
        hosting.layer?.borderWidth = near ? 2 : 0
        hosting.layer?.borderColor = NSColor.controlAccentColor.cgColor
        if near { scheduleSnapPreviewClear() }
    }

    private var screenCheckWorkItem: DispatchWorkItem?

    private func scheduleScreenCheck(delay: TimeInterval = 0.25) {
        screenCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.ensureOnScreen()
            self?.snapPanel()
        }
        screenCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 保证窗口至少有一块能抓住的区域留在屏幕内。
    /// 允许用户把它拖到半出屏幕（那是有意为之），但不能让它彻底找不回来。
    /// 注意：这里刻意不用动画。
    /// 动画期间窗口会持续发出 didMove 通知，每次都被当成用户拖动去校正，
    /// 结果把动画途中的中间位置写进了自动保存的 frame（实测存成了 1039 15）。
    private func ensureOnScreen() {
        guard panel != nil else { return }

        // 鼠标还按着就说明正在拖，等松手再说
        if NSEvent.pressedMouseButtons != 0 {
            scheduleScreenCheck()
            return
        }

        let frame = panel.frame
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let intersection = frame.intersection(visible)

        // 露出面积够大就不动它
        if intersection.width >= 80, intersection.height >= 60 { return }

        // 否则整块拉回可见范围
        var target = frame
        let maxX = max(visible.minX, visible.maxX - target.width)
        let maxY = max(visible.minY, visible.maxY - target.height)
        target.origin.x = min(max(target.minX, visible.minX), maxX)
        target.origin.y = min(max(target.minY, visible.minY), maxY)

        if ProcessInfo.processInfo.environment["DM_DEBUG_FRAME"] != nil {
            FileHandle.standardError.write(Data("CLAMP \(frame) → \(target)\n".utf8))
        }
        panel.setFrame(target, display: true)
        panel.saveFrame(usingName: Self.frameAutosaveName)
    }

    /// 把窗口拉回屏幕可见范围内
    private func clampToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = panel.screen ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        var result = frame
        let maxX = max(visible.minX, visible.maxX - result.width)
        let maxY = max(visible.minY, visible.maxY - result.height)
        result.origin.x = min(max(result.minX, visible.minX), maxX)
        result.origin.y = min(max(result.minY, visible.minY), maxY)
        return result
    }

    /// 按 SwiftUI 的内容尺寸重排面板，保持顶边不动（高度变化时视觉更稳）
    private func resizePanelToFit() {
        // 用户正在拖手柄时，任何布局回调都不许改窗口尺寸
        guard !isUserResizing, let hosting = hostingView, let panel else { return }
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        guard fitting.height > 80, fitting.width > 80 else { return }

        // 用户拖过高度就尊重手动值，不再按内容自适应
        let useManual = store.manualHeight && !store.compactMode
        let targetSize = NSSize(
            width: panel.frame.width,      // 宽度完全交给用户拖拽
            height: useManual ? panel.frame.height : fitting.height
        )

        var frame = panel.frame

        if let anchor = pendingAnchor, let screen = panel.screen ?? NSScreen.main {
            // 有锚点就按锚点重放位置——不管尺寸是否“已经”被 AppKit 改过。
            // SwiftUI 换布局时 AppKit 会先一步把窗口撑大，
            // 等我们执行到这里时尺寸往往已经对了，位置却是错的。
            let visible = screen.visibleFrame
            frame.size = targetSize
            frame.origin.x = anchor.isRight
                ? visible.maxX - targetSize.width - anchor.gap
                : visible.minX + anchor.gap
            frame.origin.y = anchor.top - targetSize.height
        } else if abs(frame.height - targetSize.height) > 0.5
            || abs(frame.width - targetSize.width) > 0.5 {
            // 没有锚点（比如模块开关触发的重排）：保持顶边不动
            let top = frame.maxY
            frame.size = targetSize
            frame.origin.y = top - targetSize.height
        }

        // 即使尺寸没变也要 clamp：AppKit 可能已经把窗口撑出屏幕
        let clamped = clampToScreen(frame)
        guard clamped != panel.frame else {
            pendingAnchor = nil
            return
        }
        isApplyingFrame = true
        panel.setFrame(clamped, display: true)
        isApplyingFrame = false
        panel.saveFrame(usingName: Self.frameAutosaveName)
        pendingAnchor = nil
    }

    /// DSH 主窗口的屏幕位置（转成 Cocoa 的左下原点坐标）
    private func frontmostDSWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner.localizedCaseInsensitiveContains("DeepSeek"),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                  width > 500, height > 400
            else { continue }
            return NSRect(x: x, y: screenHeight - y - height, width: width, height: height)
        }
        return nil
    }

    /// 拖动结束后：边贴边就吸附到 DSH 窗口或屏幕边缘
    private func snapPanel() {
        guard store.snapToDSH, let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = frontmostDSWindowFrame() ?? visible
        let threshold: CGFloat = 12

        var frame = panel.frame
        var changed = false

        if ProcessInfo.processInfo.environment["DM_DEBUG_SNAP"] != nil {
            FileHandle.standardError.write(Data(
                "SNAP panel=\(frame) target=\(target) visible=\(visible)\n".utf8))
        }

        // 位置吸附：左/右边缘
        for candidate in [target.minX, target.maxX - frame.width,
                          visible.minX, visible.maxX - frame.width] {
            if abs(frame.minX - candidate) <= threshold, frame.minX != candidate {
                frame.origin.x = candidate
                changed = true
            }
        }
        // 位置吸附：上/下边缘
        for candidate in [target.minY, target.maxY,
                          visible.minY, visible.maxY - frame.height] {
            if abs(frame.minY - candidate) <= threshold, frame.minY != candidate {
                frame.origin.y = candidate
                changed = true
            }
        }
        // 尺寸吸附：右下边贴住 DSH
        if abs(frame.maxX - target.maxX) <= threshold, frame.maxX != target.maxX {
            frame.size.width = max(200, target.maxX - frame.minX)
            changed = true
        }
        if abs(frame.maxY - target.maxY) <= threshold, frame.maxY != target.maxY {
            frame.size.height = max(160, target.maxY - frame.minY)
            changed = true
        }

        guard changed else { return }
        isApplyingFrame = true
        panel.setFrame(clampToScreen(frame), display: true)
        isApplyingFrame = false
        panel.saveFrame(usingName: Self.frameAutosaveName)
        clearSnapPreview()
    }

    /// 松手/吸完就撤掉描边，不能一直亮着
    private func clearSnapPreview() {
        guard snapPreviewOn else { return }
        snapPreviewOn = false
        hostingView?.layer?.borderWidth = 0
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        snapPanel()
    }

    /// 用户拖动高度：记下来，下次启动还原
    func windowDidResize(_ notification: Notification) {
        // 启动时 SwiftUI 会把窗口撑到自己的内容尺寸，那不是用户拖动
        guard resizeRecordingArmed, !isApplyingFrame, let panel, !store.compactMode else { return }
        let height = panel.frame.height
        guard height > 120, abs(height - store.panelHeight) > 1 else { return }
        store.manualHeight = true
        store.panelHeight = Double(height)
        UserDefaults.standard.set(true, forKey: Prefs.manualHeight)
        UserDefaults.standard.set(store.panelHeight, forKey: Prefs.panelHeight)
        panel.saveFrame(usingName: Self.frameAutosaveName)
    }

    @objc private func resetHeightToContent() {
        store.manualHeight = false
        UserDefaults.standard.set(false, forKey: Prefs.manualHeight)
        captureAnchor()
        resizePanelToFit()
    }

    /// 只做位置修正，不动尺寸
    private func clampPanel() {
        guard panel != nil else { return }
        let clamped = clampToScreen(panel.frame)
        guard clamped != panel.frame else { return }
        panel.setFrame(clamped, display: true)
        panel.saveFrame(usingName: Self.frameAutosaveName)
    }

    private func moveToDefaultPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "–"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 单独一格菜单栏：DSH 工作区任务进度。与面板卡片共用同一份快照。
    private func buildTaskItem() {
        // DSHTasksKit 的类型是 MainActor 隔离的，而 AppDelegate 不是。
        // 这些调用都发生在主线程（AppKit 生命周期 / 菜单动作），
        // 用 assumeIsolated 声明这个事实，避免把整个类搬到 MainActor 引发连锁改动。
        MainActor.assumeIsolated {
            let controller = StatusItemController(store: taskMonitor.store, order: 1)
            controller.isEnabled = store.showDSTasksInMenuBar
            controller.onOpen = { Self.openDSH() }
            taskStatusItem = controller
        }
    }

    /// 把 DSH 的主窗口带到前台（没运行就启动）。
    private static func openDSH() {
        let url = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("DeskMonitor: cannot open DSH: \(error.localizedDescription)")
            }
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = buildMenu()
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggle = item(
            title: panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
            action: #selector(togglePanel),
            key: "h"
        )
        menu.addItem(toggle)
        menu.addItem(.separator())

        // 窗口层级
        let levelRoot = item(title: "窗口层级", action: nil)
        let levelMenu = NSMenu()
        for mode in WindowLevelMode.allCases {
            let entry = item(title: mode.title, action: #selector(selectLevel(_:)))
            entry.representedObject = mode.rawValue
            entry.state = currentLevelMode == mode ? .on : .off
            levelMenu.addItem(entry)
        }
        levelRoot.submenu = levelMenu
        menu.addItem(levelRoot)

        // 点击穿透
        let through = item(title: "点击穿透", action: #selector(toggleClickThrough))
        through.state = panel.ignoresMouseEvents ? .on : .off
        menu.addItem(through)

        let compactItem = item(title: "简约模式", action: #selector(toggleCompact))
        compactItem.state = store.compactMode ? .on : .off
        menu.addItem(compactItem)
        menu.addItem(.separator())

        // 显示模块（CPU 与内存常驻，其余可关）
        let modulesRoot = item(title: "显示模块", action: nil)
        let modulesMenu = NSMenu()

        // 简约模式只有时间、CPU、内存，其余模块勾了也不会显示。
        // 与其留一个不起作用的勾选项，不如直接置灰并说明原因。
        let compactOnlyKeys: Set<String> = ["cpu", "memory"]
        if store.compactMode {
            let hint = NSMenuItem(title: "简约模式只显示时间、CPU、内存", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            modulesMenu.addItem(hint)
            modulesMenu.addItem(.separator())
        }
        let modules: [(key: String, title: String, enabled: Bool)] = [
            ("clockWeather", "时间天气", store.showClockWeather),
            ("cpu", "CPU", store.showCPU),
            ("memory", "内存", store.showMemory),
            ("network", "网络", store.showNetwork),
            ("disk", "磁盘", store.showDisk),
            ("gpu", "GPU", store.showGPU),
            ("processes", "进程列表", store.showProcesses),
            ("tasks", "DSH 任务", store.showDSTasks),
        ]
        for module in modules {
            let entry = item(title: module.title, action: #selector(toggleModule(_:)))
            entry.representedObject = module.key
            entry.state = module.enabled ? .on : .off
            entry.isEnabled = !store.compactMode || compactOnlyKeys.contains(module.key)
            modulesMenu.addItem(entry)
        }
        modulesRoot.submenu = modulesMenu
        menu.addItem(modulesRoot)

        let taskBarItem = item(title: "菜单栏显示 DSH 任务", action: #selector(toggleTaskMenuBar))
        taskBarItem.state = store.showDSTasksInMenuBar ? .on : .off
        menu.addItem(taskBarItem)
        let cityItem = item(title: "设置城市…", action: #selector(changeCity))
        cityItem.isEnabled = !store.compactMode
        menu.addItem(cityItem)

        // 不透明度
        let opacityRoot = item(title: "不透明度", action: nil)
        let opacityMenu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.5] {
            let entry = item(title: "\(Int(value * 100))%", action: #selector(selectOpacity(_:)))
            entry.representedObject = NSNumber(value: value)
            entry.state = abs(panel.alphaValue - value) < 0.01 ? .on : .off
            opacityMenu.addItem(entry)
        }
        opacityRoot.submenu = opacityMenu
        menu.addItem(opacityRoot)

        // 记住位置与尺寸（可关）
        let rememberItem = item(title: "记住窗口位置与尺寸", action: #selector(toggleRememberFrame))
        rememberItem.state = store.rememberFrame ? .on : .off
        menu.addItem(rememberItem)

        // 吸附
        let snapItem = item(title: "吸附到 DSH 窗口边缘", action: #selector(toggleSnap))
        snapItem.state = store.snapToDSH ? .on : .off
        menu.addItem(snapItem)

        // 高度：手动 / 自动
        let heightItem = item(
            title: store.manualHeight ? "高度：恢复自动适配" : "高度：固定当前高度",
            action: #selector(toggleManualHeight)
        )
        heightItem.isEnabled = !store.compactMode
        menu.addItem(heightItem)

        // 刷新间隔
        let intervalRoot = item(title: "刷新间隔", action: nil)
        let intervalMenu = NSMenu()
        for value in [0.5, 1.0, 2.0, 5.0] {
            let entry = item(title: value == 0.5 ? "0.5 秒" : "\(Int(value)) 秒", action: #selector(selectInterval(_:)))
            entry.representedObject = NSNumber(value: value)
            entry.state = abs(sampler.interval - value) < 0.01 ? .on : .off
            intervalMenu.addItem(entry)
        }
        intervalRoot.submenu = intervalMenu
        menu.addItem(intervalRoot)

        menu.addItem(.separator())

        menu.addItem(item(title: "重置窗口位置", action: #selector(resetPosition)))
        menu.addItem(item(title: "使用说明（基础）", action: #selector(openManual)))
        menu.addItem(item(title: "使用说明（进阶）", action: #selector(openAdvancedManual)))
        menu.addItem(item(title: "打开活动监视器", action: #selector(openActivityMonitor)))

        let login = item(title: "开机自启", action: #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item(title: "退出 DeskMonitor", action: #selector(quit), key: "q"))

        return menu
    }

    private func item(title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private var currentLevelMode: WindowLevelMode {
        let raw = UserDefaults.standard.string(forKey: Prefs.levelMode) ?? ""
        return WindowLevelMode(rawValue: raw) ?? .floating
    }

    // MARK: - 动作

    @objc private func togglePanel() {
        let defaults = UserDefaults.standard
        if panel.isVisible {
            panel.orderOut(nil)
            defaults.set(false, forKey: Prefs.panelVisible)
        } else {
            panel.orderFrontRegardless()
            defaults.set(true, forKey: Prefs.panelVisible)
        }
    }

    @objc private func selectLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        panel.level = mode.level
        UserDefaults.standard.set(raw, forKey: Prefs.levelMode)
    }

    @objc private func toggleClickThrough() {
        let next = !panel.ignoresMouseEvents
        panel.ignoresMouseEvents = next
        UserDefaults.standard.set(next, forKey: Prefs.clickThrough)
    }

    /// 菜单自检：确认「不可用的项」确实被置灰，而不是留个假开关
    private func dumpMenu(_ menu: NSMenu, indent: String) {
        for entry in menu.items {
            if entry.isSeparatorItem {
                FileHandle.standardError.write(Data("\(indent)---\n".utf8))
                continue
            }
            let mark = entry.state == .on ? "[x]" : "[ ]"
            let disabled = entry.isEnabled ? "" : "   ← 置灰"
            FileHandle.standardError.write(Data("\(indent)\(mark) \(entry.title)\(disabled)\n".utf8))
            if let submenu = entry.submenu {
                dumpMenu(submenu, indent: indent + "  ")
            }
        }
    }

    @objc private func toggleSnap() {
        store.snapToDSH.toggle()
        UserDefaults.standard.set(store.snapToDSH, forKey: Prefs.snapToDSH)
    }

    @objc private func toggleRememberFrame() {
        store.rememberFrame.toggle()
        UserDefaults.standard.set(store.rememberFrame, forKey: Prefs.rememberFrame)
    }

    /// 让 ⌘Q 能退出：app 是 accessory，没有菜单栏，但装了主菜单后
    /// 面板获得焦点时快捷键依然生效。
    /// 面板是 non-activating 的，⌘Q 永远落到 DSH 上。
    /// 这里注册一个全局快捷键 ⌃⌥⌘Q，专门退出 DeskMonitor。
    private func installGlobalHotKey() {
        var hotKeyRef: EventHotKeyRef?
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x444D4F4E), id: 1)  // 'DMON'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Q),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 DeskMonitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 DeskMonitor",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleManualHeight() {
        if store.manualHeight {
            resetHeightToContent()
        } else {
            store.manualHeight = true
            store.panelHeight = Double(panel?.frame.height ?? CGFloat(store.panelHeight))
            UserDefaults.standard.set(true, forKey: Prefs.manualHeight)
            UserDefaults.standard.set(store.panelHeight, forKey: Prefs.panelHeight)
        }
    }

    private var resizeMonitor: Any?
    private var resizeStartFrame: NSRect = .zero
    private var resizeStartMouse: NSPoint = .zero

    /// 手柄不走视图层：直接在事件层拦截右下角 26×26 的按下/拖动。
    /// 视图方案试了两轮都收不到事件（无边框面板 + SwiftUI 宿主视图），
    /// 事件监视器不依赖任何视图层级，最可靠。
    private func installResizeMonitor() {
        let grip: CGFloat = 26
        resizeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let point = event.locationInWindow
            let inGrip = point.x >= panel.frame.width - grip && point.y <= grip

            switch event.type {
            case .leftMouseDown:
                guard inGrip else { return event }
                self.isUserResizing = true
                self.resizeStartFrame = panel.frame
                self.resizeStartMouse = NSEvent.mouseLocation
                return nil

            case .leftMouseDragged:
                guard self.isUserResizing else { return event }
                let now = NSEvent.mouseLocation
                var frame = self.resizeStartFrame
                frame.size.width = max(200, self.resizeStartFrame.width + (now.x - self.resizeStartMouse.x))
                let dy = self.resizeStartMouse.y - now.y
                frame.size.height = max(160, self.resizeStartFrame.height + dy)
                frame.origin.y = self.resizeStartFrame.maxY - frame.size.height
                panel.setFrame(frame, display: true)
                return nil

            case .leftMouseUp:
                guard self.isUserResizing else { return event }
                self.isUserResizing = false
                self.store.manualHeight = true
                self.store.panelHeight = Double(panel.frame.height)
                self.store.panelWidthPoints = Double(panel.frame.width)
                UserDefaults.standard.set(true, forKey: Prefs.manualHeight)
                UserDefaults.standard.set(self.store.panelHeight, forKey: Prefs.panelHeight)
                UserDefaults.standard.set(self.store.panelWidthPoints, forKey: Prefs.panelWidth)
                panel.saveFrame(usingName: Self.frameAutosaveName)
                return nil

            default:
                return event
            }
        }
    }

    @objc private func selectPanelWidth(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        store.panelWidthPoints = value.doubleValue
        UserDefaults.standard.set(store.panelWidthPoints, forKey: Prefs.panelWidth)
        captureAnchor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.resizePanelToFit()
        }
    }

    @objc private func toggleCompact() {
        captureAnchor()
        store.compactMode.toggle()
        UserDefaults.standard.set(store.compactMode, forKey: Prefs.compactMode)
        syncProcessSampling()
        // 切回完整模式时把天气补上（简约模式期间是停掉的）
        if store.compactMode {
            weatherTimer?.invalidate()
            weatherTimer = nil
        } else {
            startWeather()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.resizePanelToFit()
        }
        // SwiftUI 有时在下一轮布局后才把尺寸推到窗口上，补一次位置修正
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.resizePanelToFit()
            self?.clampPanel()
        }
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        // 菜单在点击后会收起；模型开关常常要连点几个，这里在收起后重新弹出
        let reopenAt = NSEvent.mouseLocation
        captureAnchor()
        let defaults = UserDefaults.standard

        switch key {
        case "clockWeather":
            store.showClockWeather.toggle()
            defaults.set(store.showClockWeather, forKey: Prefs.showClockWeather)
            if store.showClockWeather {
                startWeather()
            } else {
                weatherTimer?.invalidate()
                weatherTimer = nil
            }
        case "cpu":
            store.showCPU.toggle()
            defaults.set(store.showCPU, forKey: Prefs.showCPU)
        case "memory":
            store.showMemory.toggle()
            defaults.set(store.showMemory, forKey: Prefs.showMemory)
        case "network":
            store.showNetwork.toggle()
            defaults.set(store.showNetwork, forKey: Prefs.showNetwork)
        case "disk":
            store.showDisk.toggle()
            defaults.set(store.showDisk, forKey: Prefs.showDisk)
        case "gpu":
            store.showGPU.toggle()
            defaults.set(store.showGPU, forKey: Prefs.showGPU)
        case "processes":
            store.showProcesses.toggle()
            defaults.set(store.showProcesses, forKey: Prefs.showProcesses)
            syncProcessSampling()
        case "tasks":
            store.showDSTasks.toggle()
            defaults.set(store.showDSTasks, forKey: Prefs.showDSTasks)
        default:
            return
        }

        // 等 SwiftUI 重新布局后再调整窗口高度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.resizePanelToFit()
        }
        // SwiftUI 有时在下一轮布局后才把尺寸推到窗口上，补一次位置修正
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.resizePanelToFit()
            self?.clampPanel()
        }

        // 菜单已经收起，重新弹出，方便连续切换多个模块
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let menu = self.statusItem?.menu else { return }
            menu.popUp(positioning: nil, at: reopenAt, in: nil)
        }
    }

    /// 单独一格菜单栏开关。任务为空时状态项本来就会自己隐藏，这里只决定「允不允许出现」。
    @objc private func toggleTaskMenuBar() {
        MainActor.assumeIsolated {
            store.showDSTasksInMenuBar.toggle()
            UserDefaults.standard.set(store.showDSTasksInMenuBar, forKey: Prefs.showDSTasksInMenuBar)
            taskStatusItem?.isEnabled = store.showDSTasksInMenuBar
        }
    }

    // MARK: - 天气

    private func startWeather() {
        // 简约模式里不显示天气，就没必要发请求
        guard store.showClockWeather, !store.compactMode else {
            weatherTimer?.invalidate()
            weatherTimer = nil
            return
        }
        weatherTimer?.invalidate()

        let timer = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            self?.refreshWeather()
        }
        RunLoop.main.add(timer, forMode: .common)
        weatherTimer = timer

        debugWeather("start: show=\(store.showClockWeather)")
        refreshWeather()
    }

    private func refreshWeather() {
        if let city = savedCity() {
            debugWeather("refresh: 使用已保存城市 \(city.name) (\(city.latitude), \(city.longitude))")
            loadWeather(for: city)
            return
        }
        // 没设置过：用时区名猜一个，例如 Asia/Shanghai → Shanghai
        guard let guess = WeatherService.guessCityFromTimeZone() else { return }
        weatherService.resolve(cityName: guess) { [weak self] city in
            guard let self, let city else { return }
            self.saveCity(city)
            self.loadWeather(for: city)
        }
    }

    /// 刚启动时网络常常还没就绪，失败后 15 秒重试，最多 12 次（3 分钟）
    private func scheduleWeatherRetry() {
        guard weatherRetryCount < 12 else { return }
        weatherRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.store.showClockWeather, !self.store.compactMode else { return }
            self.refreshWeather()
        }
    }

    private func debugWeather(_ message: String) {
        guard ProcessInfo.processInfo.environment["DM_DEBUG_WEATHER"] != nil else { return }
        FileHandle.standardError.write(Data("WEATHER \(message)\n".utf8))
    }

    private func loadWeather(for city: WeatherService.City) {
        weatherService.fetch(city) { [weak self] snapshot in
            guard let self else { return }

            if ProcessInfo.processInfo.environment["DM_DEBUG_WEATHER"] != nil {
                let temp = snapshot.temperature.map { String(format: "%.1f", $0) } ?? "nil"
                FileHandle.standardError.write(Data(
                    "WEATHER city=\(snapshot.cityName) temp=\(temp) code=\(snapshot.weatherCode.map(String.init) ?? "nil") condition=\(snapshot.condition)\n".utf8))
            }

            // 拉取失败时保留上一次的数据，不要把界面清空
            guard snapshot.isAvailable else {
                self.scheduleWeatherRetry()
                return
            }
            self.weatherRetryCount = 0
            self.store.weather = snapshot
        }
    }

    private func savedCity() -> WeatherService.City? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: Prefs.cityName), !name.isEmpty else { return nil }
        let latitude = defaults.double(forKey: Prefs.cityLatitude)
        let longitude = defaults.double(forKey: Prefs.cityLongitude)
        guard latitude != 0 || longitude != 0 else { return nil }
        return WeatherService.City(name: name, latitude: latitude, longitude: longitude)
    }

    private func saveCity(_ city: WeatherService.City) {
        let defaults = UserDefaults.standard
        defaults.set(city.name, forKey: Prefs.cityName)
        defaults.set(city.latitude, forKey: Prefs.cityLatitude)
        defaults.set(city.longitude, forKey: Prefs.cityLongitude)
    }

    @objc private func changeCity() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "设置天气城市"
        alert.informativeText = "输入城市名，例如：上海、北京、Tokyo。\n天气数据来自 Open-Meteo，只会上传这个城市的中心经纬度。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = savedCity()?.name ?? ""
        field.placeholderString = "城市名"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        weatherService.resolve(cityName: name) { [weak self] city in
            guard let self else { return }
            guard let city else {
                let failure = NSAlert()
                failure.messageText = "没找到这个城市"
                failure.informativeText = "换个写法试试，比如「上海」或「Tokyo」。"
                failure.runModal()
                return
            }
            self.saveCity(city)
            self.loadWeather(for: city)
        }
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    /// 进程列表是可选模块：关掉时连定时器一起停，不浪费 CPU
    private func syncProcessSampling() {
        processTimer?.invalidate()
        processTimer = nil

        // 简约模式里不显示进程列表，连采样一起停掉，省点 CPU
        guard store.showProcesses, !store.compactMode else {
            store.apply(processes: [])
            return
        }

        store.apply(processes: processSampler.sample())

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.apply(processes: self.processSampler.sample())
        }
        // .common 模式：菜单展开时也照常刷新
        RunLoop.main.add(timer, forMode: .common)
        processTimer = timer
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        panel.alphaValue = number.doubleValue
        UserDefaults.standard.set(number.doubleValue, forKey: Prefs.opacity)
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        UserDefaults.standard.set(number.doubleValue, forKey: Prefs.interval)
        sampler.start(interval: number.doubleValue)
        store.resetHistory()
    }

    @objc private func resetPosition() {
        moveToDefaultPosition()
        panel.saveFrame(usingName: Self.frameAutosaveName)
        panel.orderFrontRegardless()
    }

    @objc private func openAdvancedManual() {
        openBundledPDF(named: "DeskMonitor-Manual-Advanced")
    }

    private func openBundledPDF(named: String) {
        if let url = Bundle.main.url(forResource: named, withExtension: "pdf") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openManual() {
        guard let url = Bundle.main.url(forResource: "DeskMonitor-Manual", withExtension: "pdf") else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "找不到使用说明"
            alert.informativeText = "安装包里应该带一个 DeskMonitor-Manual.pdf。可以在项目的 docs 目录里找到。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法修改开机自启"
            alert.informativeText = "\(error.localizedDescription)\n\n提示：把 App 移到 /Applications 后再试成功率更高。"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() {
        sampler.stop()
        NSApp.terminate(nil)
    }

    // MARK: - 采样

    private func startSampling() {
        sampler.onSample = { [weak self] bundle in
            guard let self else { return }
            self.store.apply(bundle)
            self.updateStatusTitle()
        }
        let interval = UserDefaults.standard.double(forKey: Prefs.interval)
        sampler.start(interval: interval > 0 ? interval : 1.0)
    }

    /// 状态栏标题只在文本真的变化时才写回去。
    /// 每次赋值都会让整个状态栏重新布局，0.5 秒一次也会实打实吃掉 1% CPU。
    private func updateStatusTitle() {
        guard let statusItem else { return }
        let title = "\(Fmt.percent(store.cpu.totalUsage))  \(Fmt.compact(store.memory.used))"
        guard title != lastStatusTitle else { return }
        lastStatusTitle = title
        statusItem.button?.title = title
    }

    private func applyPreferences() {
        guard panel != nil else { return }
        let defaults = UserDefaults.standard
        panel.level = currentLevelMode.level
        let opacity = defaults.double(forKey: Prefs.opacity)
        panel.alphaValue = opacity > 0 ? opacity : 1
        panel.ignoresMouseEvents = defaults.bool(forKey: Prefs.clickThrough)
        if !defaults.bool(forKey: Prefs.panelVisible) {
            panel.orderOut(nil)
        }
    }
}
