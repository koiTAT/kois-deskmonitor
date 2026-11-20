import AppKit

/// 无边框、置顶、可跨 Space 常驻的悬浮面板。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating

        // 常驻：切 Space、进 Mission Control、全屏 App 上都还在
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = false
    }
}
