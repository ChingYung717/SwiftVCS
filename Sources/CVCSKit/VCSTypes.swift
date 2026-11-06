import Foundation

// MARK: - Errors

/// 统一的版本控制错误。底层后端（SVN/Perforce）各自的错误码在这里被归一化。
public enum VCSError: Error, LocalizedError, Sendable {
    /// 未配置或未找到凭据
    case authenticationRequired(String)
    /// 凭据被服务端拒绝
    case authenticationFailed(String)
    /// 目标路径在工作副本中不存在
    case notFound(path: String)
    /// 工作副本损坏（需要 repair）
    case workingCopyCorrupted(String)
    /// 存在未解决的冲突
    case conflictsPresent([String])
    /// 网络 / 协议层错误
    case transport(String)
    /// 服务端返回了错误消息
    case server(code: Int, message: String)
    /// 参数非法
    case invalidArgument(String)
    case notSupported(String)
    case mergeInterrupted(String)
    /// 其他
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let detail):
            return "需要凭据：\(detail)"
        case .authenticationFailed(let detail):
            return "认证失败：\(detail)"
        case .notFound(let path):
            return "路径不存在：\(path)"
        case .workingCopyCorrupted(let detail):
            return "工作副本已损坏：\(detail)"
        case .conflictsPresent(let paths):
            return "存在未解决的冲突（\(paths.count) 处）：\(paths.joined(separator: ", "))"
        case .transport(let detail):
            return "网络错误：\(detail)"
        case .server(let code, let message):
            return "服务端错误 [\(code)]：\(message)"
        case .invalidArgument(let detail):
            return "参数错误：\(detail)"
        case .notSupported(let detail):
            return "不支持：\(detail)"
        case .mergeInterrupted(let detail):
            return "合并中止，工作副本可能已有改动：\(detail)"
        case .underlying(let detail):
            return detail
        }
    }
}

// MARK: - Credentials

/// 访问服务端所需的凭据。
public struct Credentials: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        case usernamePassword(user: String, password: String)
        /// 来自 macOS 钥匙串的条目（不把密码留在内存里）
        case keychain(service: String, account: String)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public init(username: String, password: String) {
        self.init(.usernamePassword(user: username, password: password))
    }

    public static func keychain(service: String, account: String) -> Credentials {
        Credentials(.keychain(service: service, account: account))
    }
}

// MARK: - Repository

/// 仓库信息
public struct RepositoryInfo: Sendable, Equatable {
    /// 仓库连接 URL
    public let url: URL
    /// 仓库根 URL（若连接的是仓库内子目录，此字段为仓库顶层根 URL）
    public let rootURL: URL?
    /// 服务端返回的仓库 UUID（SVN 会话信息）
    public let uuid: String?
    /// 仓库根目录下的最新修订号
    public let revision: Int
    /// 仓库可读的最新修订（区别于工作副本的 BASE）
    public let youngestRevision: Int

    public init(
        url: URL,
        uuid: String?,
        revision: Int,
        youngestRevision: Int,
        rootURL: URL? = nil
    ) {
        self.url = url
        self.uuid = uuid
        self.revision = revision
        self.youngestRevision = youngestRevision
        self.rootURL = rootURL
    }
}

/// 仓库浏览树中的一个节点
public struct RepositoryEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        case symlink
    }

    public let id: String
    /// 相对仓库根的路径，例如 `trunk/src/main.swift`
    public let path: String
    public let name: String
    public let kind: Kind
    /// 该节点最后修改的修订号
    public let revision: Int
    public let size: Int64?
    public let author: String?
    public let lastModified: Date?

    public init(
        id: String,
        path: String,
        name: String,
        kind: Kind,
        revision: Int,
        size: Int64? = nil,
        author: String? = nil,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.revision = revision
        self.size = size
        self.author = author
        self.lastModified = lastModified
    }
}

// MARK: - Working copy status

public enum ConflictKind: String, CaseIterable, Sendable, Hashable {
    case text, property, tree, binary, unknown

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .property: return "属性"
        case .tree: return "树"
        case .binary: return "二进制"
        case .unknown: return "未知"
        }
    }
}

public enum ConflictResolution: String, CaseIterable, Sendable, Hashable {
    case current, base, incoming, local

    public var displayName: String {
        switch self {
        case .current: return "采用工作文件当前内容"
        case .base: return "采用冲突基线"
        case .incoming: return "采用传入版本"
        case .local: return "采用冲突前本地版本"
        }
    }
}

public struct MergeRequest: Sendable, Equatable {
    public let source: URL
    public let from: Int32
    public let to: Int32
    public let peg: Int32

    public init(source: URL, from: Int, to: Int, peg: Int? = nil) throws {
        guard let start = Int32(exactly: from), let end = Int32(exactly: to),
              let anchor = Int32(exactly: peg ?? to), start >= 0, end > start, anchor > 0 else {
            throw VCSError.invalidArgument("合并需要有效的正向修订范围和 peg 修订")
        }
        self.source = source
        self.from = start
        self.to = end
        self.peg = anchor
    }

    public init(source: URL, revision: Int, peg: Int? = nil) throws {
        guard revision > 0 else { throw VCSError.invalidArgument("合并修订必须大于零") }
        try self.init(source: source, from: revision - 1, to: revision, peg: peg)
    }
}

public struct MergeResult: Sendable, Equatable {
    public let request: MergeRequest
    public let dryRun: Bool
    public let changedPaths: [String]
    public let conflictedPaths: [String]
    public let skippedPaths: [String]
    public let refreshRequired: Bool

    public init(request: MergeRequest, dryRun: Bool, changedPaths: [String],
                conflictedPaths: [String], skippedPaths: [String], refreshRequired: Bool = false) {
        self.request = request
        self.dryRun = dryRun
        self.changedPaths = changedPaths
        self.conflictedPaths = conflictedPaths
        self.skippedPaths = skippedPaths
        self.refreshRequired = refreshRequired
    }
}

/// 工作副本中一个路径的状态
public struct WorkingCopyStatus: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case normal
        case added
        case modified
        case deleted
        case replaced
        case conflicted
        case missing
        case unversioned
        case obstructed
        case ignored
        case unknown(String)

        /// 是否是需要用户处理的改动（会进入提交）
        public var isPendingChange: Bool {
            switch self {
            case .added, .modified, .deleted, .replaced, .conflicted, .missing, .obstructed:
                return true
            case .normal, .unversioned, .ignored, .unknown:
                return false
            }
        }

        public var displayName: String {
            switch self {
            case .normal: return "正常"
            case .added: return "新增"
            case .modified: return "修改"
            case .deleted: return "删除"
            case .replaced: return "替换"
            case .conflicted: return "冲突"
            case .missing: return "丢失"
            case .unversioned: return "未版本控制"
            case .obstructed: return "受阻"
            case .ignored: return "已忽略"
            case .unknown(let raw): return raw
            }
        }
    }

    public let id: String
    /// 相对工作副本根的路径
    public let path: String
    public let name: String
    public let kind: Kind
    /// 工作副本当前所基于的修订号
    public let baseRevision: Int
    /// 若已提交，该文件的新修订号
    public let workingRevision: Int?
    /// 是否为目录
    public let isDirectory: Bool
    /// 本地修改的锁（若被锁定）
    public let lockOwner: String?
    public let movedFrom: String?
    public let movedTo: String?
    public let conflictKinds: Set<ConflictKind>
    public let resolutions: Set<ConflictResolution>
    public let mergeInfoChanged: Bool
    public let movedDestinationModified: Bool

    public init(
        id: String,
        path: String,
        name: String,
        kind: Kind,
        baseRevision: Int,
        workingRevision: Int? = nil,
        isDirectory: Bool = false,
        lockOwner: String? = nil,
        movedFrom: String? = nil,
        movedTo: String? = nil,
        conflictKinds: Set<ConflictKind> = [],
        resolutions: Set<ConflictResolution> = [],
        mergeInfoChanged: Bool = false,
        movedDestinationModified: Bool = false
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.baseRevision = baseRevision
        self.workingRevision = workingRevision
        self.isDirectory = isDirectory
        self.lockOwner = lockOwner
        self.movedFrom = movedFrom
        self.movedTo = movedTo
        self.conflictKinds = conflictKinds
        self.resolutions = resolutions
        self.mergeInfoChanged = mergeInfoChanged
        self.movedDestinationModified = movedDestinationModified
    }
}

// MARK: - Diff

/// 并排对比视图中的单行（左右可为空）
public struct SplitDiffRow: Sendable, Hashable, Identifiable {
    public let id: Int
    public let left: FileDiff.Hunk.Line?
    public let right: FileDiff.Hunk.Line?

    public init(id: Int, left: FileDiff.Hunk.Line?, right: FileDiff.Hunk.Line?) {
        self.id = id
        self.left = left
        self.right = right
    }
}

public typealias SplitRow = SplitDiffRow

public enum SideBySide {
    public static func rows(for hunk: FileDiff.Hunk) -> [SplitDiffRow] {
        hunk.splitRows
    }
}

/// 单个文件的差异
public struct FileDiff: Sendable, Hashable, Identifiable {
    public struct Hunk: Sendable, Hashable, Identifiable {
        public struct Line: Sendable, Hashable, Identifiable {
            public enum Kind: Sendable, Hashable {
                case context
                case addition
                case deletion
            }
            public let id: UUID
            public let kind: Kind
            public let text: String
            /// 原文件行号（1 起）
            public let oldLine: Int?
            /// 新文件行号（1 起）
            public let newLine: Int?

            public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
                self.id = UUID()
                self.kind = kind
                self.text = text
                self.oldLine = oldLine
                self.newLine = newLine
            }
        }

        public let id: UUID
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let header: String
        public var lines: [Line]

        /// 将连续删除行与紧随的新增行按行配对，上下文行左右相同
        public var splitRows: [SplitDiffRow] {
            var rows: [SplitDiffRow] = []
            var deletions: [Line] = []
            var additions: [Line] = []
            var nextID = 0

            func flush() {
                let count = max(deletions.count, additions.count)
                guard count > 0 else { return }
                for i in 0..<count {
                    let left = i < deletions.count ? deletions[i] : nil
                    let right = i < additions.count ? additions[i] : nil
                    rows.append(SplitDiffRow(id: nextID, left: left, right: right))
                    nextID += 1
                }
                deletions.removeAll(keepingCapacity: true)
                additions.removeAll(keepingCapacity: true)
            }

            for line in lines {
                switch line.kind {
                case .deletion:
                    if !additions.isEmpty {
                        flush()
                    }
                    deletions.append(line)
                case .addition:
                    additions.append(line)
                case .context:
                    flush()
                    rows.append(SplitDiffRow(id: nextID, left: line, right: line))
                    nextID += 1
                }
            }
            flush()
            return rows
        }

        public init(
            oldStart: Int,
            oldCount: Int,
            newStart: Int,
            newCount: Int,
            header: String,
            lines: [Line]
        ) {
            self.id = UUID()
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.header = header
            self.lines = lines
        }
    }

    public let id: String
    /// 相对工作副本根或仓库根的路径
    public let path: String
    /// 工作副本里的绝对路径或远端文件 URL
    public let localPath: URL
    public let isBinary: Bool
    /// 旧内容为空表示「新增」，新内容为空表示「删除」
    public let hunks: [Hunk]
    /// 是否因超出字节上限而被截断
    public let isTruncated: Bool
    /// 特殊状态提示说明（如二进制占位、复制来源未改动、目录等）
    public let statusNotice: String?

    /// 变更统计
    public var addedCount: Int {
        hunks.flatMap(\.lines).filter { $0.kind == .addition }.count
    }

    public var removedCount: Int {
        hunks.flatMap(\.lines).filter { $0.kind == .deletion }.count
    }

    public init(
        id: String,
        path: String,
        localPath: URL,
        isBinary: Bool,
        hunks: [Hunk],
        isTruncated: Bool = false,
        statusNotice: String? = nil
    ) {
        self.id = id
        self.path = path
        self.localPath = localPath
        self.isBinary = isBinary
        self.hunks = hunks
        self.isTruncated = isTruncated
        self.statusNotice = statusNotice
    }
}

// MARK: - Commit / Update

/// 提交结果
public struct CommitResult: Sendable, Equatable {
    /// 新产生的修订号
    public let revision: Int
    /// 已提交的文件数
    public let committedCount: Int
    /// 服务端返回的提交说明（可能经过服务端加工）
    public let message: String

    public init(revision: Int, committedCount: Int, message: String) {
        self.revision = revision
        self.committedCount = committedCount
        self.message = message
    }
}

/// 同步结果
public struct UpdateResult: Sendable, Equatable {
    /// 工作副本更新到的修订号
    public let revision: Int
    /// 从仓库拉取的文件数
    public let updatedCount: Int
    /// 本地新增的文件数
    public let addedCount: Int
    /// 本地删除的文件数
    public let deletedCount: Int
    /// 仍未解决的冲突路径
    public let conflicts: [String]

    public init(
        revision: Int,
        updatedCount: Int,
        addedCount: Int,
        deletedCount: Int,
        conflicts: [String]
    ) {
        self.revision = revision
        self.updatedCount = updatedCount
        self.addedCount = addedCount
        self.deletedCount = deletedCount
        self.conflicts = conflicts
    }
}

// MARK: - Log

/// 某次提交中单个路径的结构化改动描述
public struct ChangedPath: Sendable, Hashable, Identifiable {
    public enum Action: String, Sendable, Hashable, CaseIterable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case replaced = "R"

        public var displayName: String {
            switch self {
            case .added: return "新增"
            case .modified: return "修改"
            case .deleted: return "删除"
            case .replaced: return "替换"
            }
        }

        public init(svnChar: Character) {
            switch svnChar {
            case "A", "a": self = .added
            case "D", "d": self = .deleted
            case "R", "r": self = .replaced
            default:       self = .modified
            }
        }
    }

    public enum NodeKind: String, Sendable, Hashable {
        case file
        case directory
        case unknown
    }

    public var id: String { path }
    public let action: Action
    /// 相对仓库根的路径，例如 `/Develop/module2/Foo.java`
    public let path: String
    public let kind: NodeKind
    public var nodeKind: NodeKind { kind }
    public let copyFromPath: String?
    public let copyFromRevision: Int?

    /// 文件名（路径最后一段）
    public var fileName: String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return path }
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    /// 所在目录路径
    public var directoryPath: String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/"), idx != trimmed.startIndex else {
            return trimmed.hasPrefix("/") ? "/" : ""
        }
        return String(trimmed[..<idx])
    }

    public init(
        action: Action,
        path: String,
        kind: NodeKind = .unknown,
        copyFromPath: String? = nil,
        copyFromRevision: Int? = nil
    ) {
        self.action = action
        self.path = path
        self.kind = kind
        self.copyFromPath = copyFromPath
        self.copyFromRevision = copyFromRevision
    }

    public init(
        action: Action,
        path: String,
        nodeKind: NodeKind,
        copyFromPath: String? = nil,
        copyFromRevision: Int? = nil
    ) {
        self.init(
            action: action,
            path: path,
            kind: nodeKind,
            copyFromPath: copyFromPath,
            copyFromRevision: copyFromRevision
        )
    }

    /// 从 `"M /path/to/file"` 字符串解析生成 `ChangedPath`
    public static func parse(
        _ raw: String,
        kind: NodeKind = .unknown,
        copyFromPath: String? = nil,
        copyFromRevision: Int? = nil
    ) -> ChangedPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 3 {
            let first = trimmed[trimmed.startIndex]
            let secondIdx = trimmed.index(after: trimmed.startIndex)
            if trimmed[secondIdx] == " " {
                let pathStart = trimmed.index(after: secondIdx)
                let pathStr = String(trimmed[pathStart...])
                return ChangedPath(
                    action: Action(svnChar: first),
                    path: pathStr,
                    kind: kind,
                    copyFromPath: copyFromPath,
                    copyFromRevision: copyFromRevision
                )
            }
        }
        return ChangedPath(
            action: .modified,
            path: trimmed,
            kind: kind,
            copyFromPath: copyFromPath,
            copyFromRevision: copyFromRevision
        )
    }
}

/// 一条历史记录
public struct LogEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let revision: Int
    public let author: String
    public let date: Date
    public let message: String
    /// 该修订中被改动的路径（字符串格式，如 `"M /path"`）
    public let changedPaths: [String]
    /// 该修订的结构化变更路径列表
    public let changes: [ChangedPath]

    public init(
        id: String,
        revision: Int,
        author: String,
        date: Date,
        message: String,
        changedPaths: [String],
        changes: [ChangedPath] = []
    ) {
        self.id = id
        self.revision = revision
        self.author = author
        self.date = date
        self.message = message
        self.changedPaths = changedPaths
        if changes.isEmpty && !changedPaths.isEmpty {
            self.changes = changedPaths.map { ChangedPath.parse($0) }
        } else {
            self.changes = changes
        }
    }
}

// MARK: - Progress

/// 长耗时操作的进度回调
public struct VCSTaskProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    public let currentPath: String?

    public init(phase: String, completed: Int, total: Int, currentPath: String?) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }
}

public enum PropertyTarget: Sendable, Hashable {
    case workingCopy(root: URL, path: String)
    case repository(URL)

    public var displayPath: String {
        switch self {
        case .workingCopy(_, let path): return path
        case .repository(let url): return url.absoluteString
        }
    }
}

public struct NodeProperty: Sendable, Equatable, Identifiable {
    public struct ID: Sendable, Hashable {
        public let target: PropertyTarget
        public let source: String?
        public let name: String
    }

    public let target: PropertyTarget
    public let source: String?
    public let name: String
    public let value: Data
    public var id: ID { ID(target: target, source: source, name: name) }

    public init(target: PropertyTarget, source: String?, name: String, value: Data) {
        self.target = target
        self.source = source
        self.name = name
        self.value = value
    }

    public static func allowsEditing(_ name: String) -> Bool {
        !name.isEmpty && (!name.hasPrefix("svn:") ||
            ["svn:ignore", "svn:eol-style", "svn:keywords", "svn:mime-type"].contains(name))
    }

    public var isEditable: Bool {
        guard case .workingCopy = target, source == nil else { return false }
        return Self.allowsEditing(name)
    }

    public var textValue: String? {
        value.contains(0) ? nil : String(data: value, encoding: .utf8)
    }
}

public struct IgnoreRules: Sendable, Equatable {
    public let defaults: [String]
    public let directoryRules: NodeProperty?
    public let globalRules: [NodeProperty]

    public init(defaults: [String], directoryRules: NodeProperty?, globalRules: [NodeProperty]) {
        self.defaults = defaults
        self.directoryRules = directoryRules
        self.globalRules = globalRules
    }
}
