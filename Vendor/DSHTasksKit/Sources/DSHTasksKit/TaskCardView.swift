import SwiftUI

/// The DSH task block embedded in DeskMonitor's panel.
///
/// Deliberately reads like the rest of that panel: monospaced digits, 11 pt
/// labels, thin white separators, and one accent colour for the active row.
public struct DSTaskCard: View {
    @ObservedObject private var monitor: TaskMonitor
    private let maxSessions: Int

    public init(monitor: TaskMonitor, maxSessions: Int = 3) {
        self.monitor = monitor
        self.maxSessions = maxSessions
    }

    private var hasSessions: Bool {
        !(monitor.snapshot?.sessions.isEmpty ?? true)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let snapshot = monitor.snapshot, hasSessions {
                ForEach(Array(snapshot.sessions.prefix(maxSessions))) { session in
                    TaskRow(session: session)
                    if session.id != snapshot.sessions.prefix(maxSessions).last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
                if snapshot.sessions.count > maxSessions {
                    Text("另有 \(snapshot.sessions.count - maxSessions) 个会话")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 6)
                }
            } else {
                Text(monitor.failure ?? "暂无进行中的任务")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text("DSH 任务")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 4)
            if let snapshot = monitor.snapshot, hasSessions, snapshot.overall.total > 0 {
                Text("\(snapshot.overall.completed)/\(snapshot.overall.total)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.44))
            }
        }
        .padding(.bottom, 8)
    }
}

/// One session line. Sessions without a todo list appear only while they are
/// running or waiting for approval, and show a status word instead of a bar.
private struct TaskRow: View {
    let session: ProgressSnapshot.Session

    private var accent: Color {
        if session.isWaiting { return .orange }
        if session.isRunning { return .accentColor }
        if session.isDone { return .green }
        return Color.white.opacity(0.28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(session.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if session.total == 0 {
                    Text(session.isWaiting ? "等待确认" : "运行中")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                } else if session.isRunning {
                    // 清单打勾了但 agent 还在跑：必须让「运行中」压过分数，否则看起来像结束了
                    Text("运行中")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .padding(.trailing, 2)
                }
                if session.total > 0 {
                    Text("\(session.counts.completed)/\(session.total)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }

            if session.total > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule()
                            .fill(accent.opacity(session.isDone ? 0.55 : 0.85))
                            .frame(width: max(2, proxy.size.width * min(1, max(0, session.progress))))
                    }
                }
                .frame(height: 3)

                if let task = session.activeTodo?.content ?? session.nextTodo?.content {
                    Text(session.activeTodo == nil ? "下一个 · \(task)" : task)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
