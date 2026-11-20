import Foundation

/// One published snapshot of the DSH workspace progress document.
///
/// The shape mirrors `~/.dsh/state/workspace-progress.json`, which the DSH host
/// plugin writes on every change; decoding ignores unknown fields so a newer
/// plugin can add data without breaking an older menu bar build.
public struct ProgressSnapshot: Codable, Sendable {
    public struct Workspace: Codable, Sendable {
        public let root: String?
        public let name: String?
        public init(root: String?, name: String?) {
            self.root = root
            self.name = name
        }
    }

    public struct Overall: Codable, Sendable {
        public let completed: Int
        public let total: Int
        public let sessions: Int
        public let running: Int
        public init(completed: Int, total: Int, sessions: Int, running: Int) {
            self.completed = completed
            self.total = total
            self.sessions = sessions
            self.running = running
        }
    }

    public struct Counts: Codable, Sendable {
        public let pending: Int
        public let inProgress: Int
        public let completed: Int
        public init(pending: Int, inProgress: Int, completed: Int) {
            self.pending = pending
            self.inProgress = inProgress
            self.completed = completed
        }
    }

    public struct Todo: Codable, Sendable, Identifiable {
        public let content: String
        public let status: String
        public var id: String { content }
        public init(content: String, status: String) {
            self.content = content
            self.status = status
        }
        public var isCompleted: Bool { status == "completed" }
        public var isInProgress: Bool { status == "in_progress" }
    }

    public struct Session: Codable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let cwd: String?
        public let status: String
        public let updatedAt: Double
        public let todos: [Todo]
        public let counts: Counts
        public let total: Int
        public let progress: Double
        public init(id: String, title: String, cwd: String?, status: String, updatedAt: Double,
                    todos: [Todo], counts: Counts, total: Int, progress: Double) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.status = status
            self.updatedAt = updatedAt
            self.todos = todos
            self.counts = counts
            self.total = total
            self.progress = progress
        }

        /// The task currently being worked on, if any.
        public var activeTodo: Todo? { todos.first(where: \.isInProgress) }
        /// The next unfinished task, used when nothing is in progress.
        public var nextTodo: Todo? {
            todos.first { !$0.isCompleted && !$0.isInProgress } ?? todos.first { $0.isInProgress }
        }
        public var isRunning: Bool { status == "running" }
        public var isWaiting: Bool { status == "waiting" }
        public var isDone: Bool { status == "done" }
    }

    public let version: Int
    public let updatedAt: Double
    public let workspace: Workspace
    public let overall: Overall
    public let focus: String?
    public let sessions: [Session]

    /// The session the menu bar summarises, following the host's `focus` choice.
    public var focusedSession: Session? {
        if let focus, let match = sessions.first(where: { $0.id == focus }) { return match }
        return sessions.first
    }

    /// The line the menu bar shows as text: progress plus the active task.
    /// `nil` when there is nothing worth showing, which lets the item hide.
    public func menuBarTitle(taskNameLimit: Int = 12) -> String? {
        guard let session = focusedSession else { return nil }
        if session.total == 0 {
            if session.isWaiting { return "等确认" }
            return session.isRunning ? "运行中" : nil
        }
        let fraction = "\(session.counts.completed)/\(session.total)"
        guard let task = session.activeTodo?.content ?? session.nextTodo?.content else { return fraction }
        return "\(fraction) \(Self.truncate(task, limit: taskNameLimit))"
    }

    /// Shorten a task line without cutting a surrogate pair.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

/// Errors surfaced when the snapshot file is unreadable.
public enum SnapshotError: Error, CustomStringConvertible {
    case missing(URL)
    case malformed(URL, String)

    public var description: String {
        switch self {
        case .missing(let url): return "尚未收到 DSH 的任务快照：\(url.path)"
        case .malformed(let url, let reason): return "任务快照无法解析（\(reason)）：\(url.path)"
        }
    }
}
