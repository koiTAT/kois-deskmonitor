import AppKit

/// Draws the menu bar progress ring.
///
/// A template image (alpha only) is used for the ordinary states so macOS tints
/// it for light, dark, and highlighted menu bars; the attention state keeps its
/// amber colour so a pending approval is visible at a glance.
public enum TaskRing {
    public struct Style: Sendable {
        public var progress: Double
        public var attention: Bool
        /// 圆心点：会话正在跑（哪怕清单已经全打勾），用来区分「做完了」和「还在干活」
        public var active: Bool
        public var size: CGFloat

        public init(progress: Double, attention: Bool = false, active: Bool = false, size: CGFloat = 18) {
            self.progress = min(1, max(0, progress))
            self.attention = attention
            self.active = active
            self.size = size
        }
    }

    /// Render one ring at the requested progress.
    public static func image(for style: Style) -> NSImage {
        let size = NSSize(width: style.size, height: style.size)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (min(rect.width, rect.height) - 3) / 2
            let stroke: CGFloat = 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = stroke
            let trackColor = style.attention
                ? NSColor.systemOrange.withAlphaComponent(0.35)
                : NSColor.black.withAlphaComponent(0.30)
            trackColor.setStroke()
            track.stroke()

            if style.progress > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * style.progress,
                    clockwise: true
                )
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                (style.attention ? NSColor.systemOrange : NSColor.black).setStroke()
                arc.stroke()
            }

            if style.active {
                let dot: CGFloat = 3.4
                let centerDot = NSBezierPath(ovalIn: NSRect(
                    x: center.x - dot / 2,
                    y: center.y - dot / 2,
                    width: dot,
                    height: dot
                ))
                (style.attention ? NSColor.systemOrange : NSColor.black).setFill()
                centerDot.fill()
            }
            return true
        }
        image.isTemplate = !style.attention
        return image
    }
}
