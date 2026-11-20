import AppKit
import SwiftUI

// MARK: - 配色
enum Palette {
    static let cpu = Color(red: 0.33, green: 0.80, blue: 0.98)
    static let cpuEfficiency = Color(red: 0.33, green: 0.80, blue: 0.98).opacity(0.45)

    static let appMemory = Color(red: 0.62, green: 0.55, blue: 0.99)
    static let wired = Color(red: 1.00, green: 0.63, blue: 0.36)
    static let compressed = Color(red: 1.00, green: 0.40, blue: 0.52)
    static let cached = Color(red: 0.52, green: 0.57, blue: 0.65)

    static let netDown = Color(red: 0.32, green: 0.78, blue: 0.98)
    static let netUp = Color(red: 1.00, green: 0.62, blue: 0.38)
    static let diskIO = Color(red: 0.42, green: 0.86, blue: 0.68)
    static let gpu = Color(red: 0.80, green: 0.55, blue: 0.99)

    static let good = Color(red: 0.36, green: 0.86, blue: 0.58)
    static let warn = Color(red: 1.00, green: 0.75, blue: 0.30)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.36)

    static func pressure(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: return good
        case .warning: return warn
        case .critical: return danger
        }
    }
}

// MARK: - 毛玻璃底
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

// MARK: - 窗口拖拽区
/// 无边框窗口不能靠 `isMovableByWindowBackground` 拖动（SwiftUI 会吃掉事件），
/// 所以在标题栏铺一层透明 NSView，自己接管拖拽。
struct WindowDragArea: NSViewRepresentable {
    /// 双击时的动作（用于一键切换简约 / 完整）
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

// MARK: - 迷你折线图
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.6
    var showHead: Bool = true
    /// 满量程对应的数值。默认 1 表示 values 已经是 0...1 的比率
    var fullScale: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if values.count >= 2 {
                let points = makePoints(in: size)
                ZStack(alignment: .topLeading) {
                    areaPath(points, in: size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.30), color.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                    if showHead, let head = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 4.5, height: 4.5)
                            .position(head)
                            .shadow(color: color.opacity(0.9), radius: 3)
                    }
                }
            }
        }
    }

    private func makePoints(in size: CGSize) -> [CGPoint] {
        let insetY: CGFloat = 3
        let insetX: CGFloat = 2
        let usable = max(1, size.height - insetY * 2)
        let usableX = max(1, size.width - insetX * 2)
        let strideX = usableX / CGFloat(max(1, values.count - 1))
        let scale = max(0.000_001, fullScale)
        return values.enumerated().map { index, value in
            let clamped = min(1, max(0, value / scale))
            return CGPoint(
                x: insetX + CGFloat(index) * strideX,
                y: insetY + usable * (1 - CGFloat(clamped))
            )
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func areaPath(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - 每核柱状图
//
// 注意：这里刻意**不加**隐式动画。
// 实测给数值加 .animation 会让整个 NSHostingView 每秒做 60Hz 全量重绘
// （字形/毛玻璃/阴影全部重新栅格化），空载 CPU 从 1.9% 飙到 19.8%。
// 对监视器来说，数据密度比动画重要。
struct CoreBars: View {
    var values: [Double]
    /// 性能核数量，0 表示不区分
    var performanceCount: Int

    var body: some View {
        VStack(spacing: 4) {
            // 每根柱子占一个等宽单元格，柱身限制宽度后居中。
            // 这样 10 个核正好铺满整行，不会挤在左边留一大片空白。
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    ZStack(alignment: .bottom) {
                        // 背景轨道：低负载时也能看出这是柱状图
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(.white.opacity(0.055))
                            .frame(height: 30)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(color(for: index))
                            .frame(height: max(2.5, CGFloat(min(1, max(0, values[index]))) * 30))
                    }
                    .frame(maxWidth: 11)        // 柱身最宽 11pt
                    .frame(maxWidth: .infinity) // 单元格平分整行
                }
            }
            .frame(height: 30, alignment: .bottom)

            // 核心编号，方便对号入座
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(color(for: index).opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        guard performanceCount > 0, performanceCount < values.count else {
            return Palette.cpu
        }
        // 实测（M4）：能效核排在前面，性能核在最后 N 个。
        // 用 4 个单线程满载进程验证——只有末尾 4 个跑到 100%。
        let efficiencyCount = values.count - performanceCount
        return index < efficiencyCount ? Palette.cpuEfficiency : Palette.cpu
    }
}

// MARK: - 分段占用条
struct SegmentedBar: View {
    struct Segment {
        var ratio: Double
        var color: Color
    }

    var segments: [Segment]
    var height: CGFloat = 9

    var body: some View {
        Canvas { context, size in
            let outer = Path(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: size.height / 2
            )
            context.fill(outer, with: .color(.white.opacity(0.10)))

            context.drawLayer { layer in
                layer.clip(to: outer)
                var x: CGFloat = 0
                for segment in segments {
                    let width = size.width * CGFloat(min(1, max(0, segment.ratio)))
                    guard width > 0.6 else { continue }
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    layer.fill(Path(rect), with: .color(segment.color))
                    x += width
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - 状态徽标
struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - 小号文本
struct DetailLabel: View {
    var title: String
    var value: String
    var color: Color = .white.opacity(0.35)

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(color)
            Text(value)
                .foregroundStyle(.white.opacity(0.62))
                .monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
    }
}


/// 右下角缩放手柄。
/// 无边框窗口在 macOS 上不给边缘缩放区，用户根本抓不到——
/// 所以这里自己画一个手柄，拖动时直接改窗口尺寸。
struct WindowResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            var frame = startFrame
            // 宽：右边缘跟着鼠标走（原点不变即可）
            frame.size.width = max(200, startFrame.width + (now.x - startMouse.x))
            // 高：底边缘跟着鼠标走。原点是左下角，所以必须同步移动原点，
            // 否则改高度只会动上边，表现成“往上拖反而往下缩”。
            let dy = startMouse.y - now.y
            frame.size.height = max(160, startFrame.height + dy)
            frame.origin.y = startFrame.maxY - frame.size.height
            window.setFrame(frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            NotificationCenter.default.post(name: .dmManualResize, object: nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath()
            for offset in stride(from: 4.0, through: 12.0, by: 4.0) {
                path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + offset))
            }
            NSColor.white.withAlphaComponent(0.28).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }
}


/// 八向缩放：四条边 + 四个角都能拖。
/// 只在外圈 6pt 内接管鼠标，内部交给 SwiftUI，所以不影响点击和拖拽。
final class ResizeBorderView: NSView {
    private let thickness: CGFloat = 6
    private enum Zone { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    private var activeZone: Zone?
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let b = bounds
        let nearLeft = p.x <= thickness
        let nearRight = p.x >= b.maxX - thickness
        let nearTop = p.y >= b.maxY - thickness
        let nearBottom = p.y <= thickness
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }
        return self
    }

    private func zone(at p: NSPoint) -> Zone {
        let b = bounds
        let nearLeft = p.x <= thickness
        let nearRight = p.x >= b.maxX - thickness
        let nearTop = p.y >= b.maxY - thickness
        let nearBottom = p.y <= thickness
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        default: return .bottom
        }
    }

    override func resetCursorRects() {
        let t = thickness
        let b = bounds
        addCursorRect(NSRect(x: 0, y: t, width: t, height: b.height - 2 * t), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - t, y: t, width: t, height: b.height - 2 * t), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: t, y: b.maxY - t, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: t, y: 0, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: t, height: t), cursor: .crosshair)
        addCursorRect(NSRect(x: b.maxX - t, y: 0, width: t, height: t), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: b.maxY - t, width: t, height: t), cursor: .crosshair)
        addCursorRect(NSRect(x: b.maxX - t, y: b.maxY - t, width: t, height: t), cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        activeZone = zone(at: convert(event.locationInWindow, from: nil))
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let zone = activeZone else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        var f = startFrame
        let minW: CGFloat = 200, minH: CGFloat = 160

        switch zone {
        case .left, .topLeft, .bottomLeft:
            let newW = max(minW, startFrame.width - dx)
            f.origin.x = startFrame.maxX - newW
            f.size.width = newW
        case .right, .topRight, .bottomRight:
            f.size.width = max(minW, startFrame.width + dx)
        default: break
        }
        switch zone {
        case .top, .topLeft, .topRight:
            let newH = max(minH, startFrame.height + dy)
            f.origin.y = startFrame.maxY - newH
            f.size.height = newH
        case .bottom, .bottomLeft, .bottomRight:
            f.size.height = max(minH, startFrame.height - dy)
            f.origin.y = startFrame.maxY - f.size.height
        default: break
        }
        window.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeZone = nil
        NotificationCenter.default.post(name: .dmManualResize, object: nil)
    }
}


/// 原生缩放手柄：直接作为 NSView 挂在窗口内容上。
/// 不走 SwiftUI overlay —— 后者在拖动中会被重建，导致拖拽被中断。
final class ResizeGripNative: NSView {
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        for offset in stride(from: 6.0, through: 18.0, by: 4.0) {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 4))
            path.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + offset))
        }
        NSColor.white.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1.3
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        NotificationCenter.default.post(name: .dmResizeBegan, object: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        var frame = startFrame
        frame.size.width = max(200, startFrame.width + (now.x - startMouse.x))
        let dy = startMouse.y - now.y
        frame.size.height = max(160, startFrame.height + dy)
        frame.origin.y = startFrame.maxY - frame.size.height
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        NotificationCenter.default.post(name: .dmResizeEnded, object: nil)
    }
}
