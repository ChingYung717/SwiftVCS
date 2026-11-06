import Foundation

/// 版本控制后端的统一抽象。
///
/// 设计目标：上层（GUI / CLI）只依赖这个协议，后端可插拔。
/// 当前实现为 SVN（`CSVNKit`）；接入 Perforce 时只需再写一个遵循本协议的类型。
///
/// 所有方法都是 `async`，因为底层 libsvn 的回调式 API 会被包装成 continuation。
/// 实现必须保证：同一实例上的方法可以并发调用（libsvn 的会话对象按需加锁）。
public protocol RepositoryClient: AnyObject, Sendable {

    // MARK: 连接

    /// 建立到仓库的会话。
    ///
    /// - Parameters:
    ///   - url: 仓库根 URL，例如 `https://svn.example.com/repo`
    ///   - credentials: 凭据；为 `nil` 时后端使用已配置的凭据
    func connect(to url: URL, credentials: Credentials?) async throws -> RepositoryInfo

    /// 断开并释放会话资源。
    func disconnect() async

    // MARK: 浏览

    /// 列出仓库中的某一级目录。
    ///
    /// - Parameter path: 相对仓库根的路径；`nil` 或 `""` 表示根目录
    func browse(path: String?) async throws -> [RepositoryEntry]

    // MARK: 工作副本

    /// 检出（checkout）到本地。
    ///
    /// - Parameters:
    ///   - path: 要检出的仓库内路径；`nil` 表示整个仓库
    ///   - destination: 本地目标目录
    ///   - revision: 目标修订号；`nil` 表示最新
    @discardableResult
    func checkout(path: String?, to destination: URL, revision: Int?) async throws -> URL

    /// 同步（update）已有工作副本。
    func update(workingCopy: URL, revision: Int?, progress: (@Sendable (VCSTaskProgress) -> Void)?) async throws -> UpdateResult

    /// 查询工作副本中所有待处理的改动。
    func status(of workingCopy: URL) async throws -> [WorkingCopyStatus]

    /// 回滚（revert）本地改动。
    @discardableResult
    func revert(workingCopy: URL, paths: [String]) async throws -> Int

    // MARK: 差异

    /// 计算工作副本相对基线版本的差异。
    func diff(workingCopy: URL, paths: [String]) async throws -> [FileDiff]

    /// 计算某次修订中单个改动文件的差异。
    func diffFile(
        revision: Int,
        change: ChangedPath,
        repoRootURL: URL?,
        maxBytes: Int
    ) async throws -> FileDiff

    /// 计算某次修订中所有改动文件（或指定路径过滤）的差异。
    func diffRevision(
        _ revision: Int,
        path: String?,
        maxBytes: Int
    ) async throws -> [FileDiff]

    // MARK: 提交

    /// 提交本地改动。
    func commit(
        workingCopy: URL,
        paths: [String],
        message: String,
        progress: (@Sendable (VCSTaskProgress) -> Void)?
    ) async throws -> CommitResult

    // MARK: 历史

    /// 读取提交日志。
    func log(
        workingCopy: URL,
        path: String?,
        limit: Int,
        startRevision: Int?
    ) async throws -> [LogEntry]
}

public extension RepositoryClient {
    func diffFile(
        revision: Int,
        change: ChangedPath,
        repoRootURL: URL? = nil
    ) async throws -> FileDiff {
        try await diffFile(
            revision: revision,
            change: change,
            repoRootURL: repoRootURL,
            maxBytes: 2 * 1024 * 1024
        )
    }

    func diffRevision(
        _ revision: Int,
        path: String? = nil
    ) async throws -> [FileDiff] {
        try await diffRevision(
            revision,
            path: path,
            maxBytes: 2 * 1024 * 1024
        )
    }
}

/// 工作副本在磁盘上的元信息
public struct WorkingCopyInfo: Sendable, Equatable {
    /// 工作副本根目录
    public let root: URL
    /// 工作副本所连接的仓库 URL
    public let repositoryURL: URL
    /// 当前 BASE 修订号
    public let revision: Int

    public init(root: URL, repositoryURL: URL, revision: Int) {
        self.root = root
        self.repositoryURL = repositoryURL
        self.revision = revision
    }
}
