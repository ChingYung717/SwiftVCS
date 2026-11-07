import CVCSKit
import CSVNShim
import Foundation

/// SVN 后端：把 libsvn 的同步 C 接口包装成 `RepositoryClient` 协议。
///
/// 线程模型：所有 libsvn 调用都排到一条私有串行队列上执行，
/// 因此不会阻塞协作式线程池，也天然满足 `RepositoryClient` 的并发调用要求。
public final class SVNClient: RepositoryClient, @unchecked Sendable {

    // MARK: 存储

    private struct ScopedCredentials {
        var url: URL?
        var username: String?
        var password: String?
        var realm: String?
    }

    private final class OperationCancelState: @unchecked Sendable {
        var isCancelled = false
    }

    private var _handle: OpaquePointer?
    private var activeOperation: OperationCancelState?
    private var handle: OpaquePointer? {
        get { stateLock.withLock { _handle } }
        set { stateLock.withLock { _handle = newValue } }
    }
    private let queue = DispatchQueue(label: "vcs.svn.backend", qos: .userInitiated)
    private let stateLock = NSLock()
    private let configDir: String?
    private let trustBundlePath: String?
    private let useSavedCredentials: Bool
    private var scopedCredentials: ScopedCredentials
    private var rememberedConnection: (url: URL, username: String, password: String, realm: String)?
    private var _baseURL: URL?
    private var _rootURL: URL?

    private var baseURL: URL? {
        get { stateLock.withLock { _baseURL } }
        set { stateLock.withLock { _baseURL = newValue } }
    }

    public private(set) var rootURL: URL? {
        get { stateLock.withLock { _rootURL } }
        set { stateLock.withLock { _rootURL = newValue } }
    }

    public var repositoryRoot: URL? {
        stateLock.withLock { _rootURL }
    }

    // MARK: 初始化

    /// 自定义 CA 通过当前 SVN 上下文的配置传递。
    public init(
        username: String? = nil,
        password: String? = nil,
        configDir: String? = nil,
        trustBundlePath: String? = nil,
        baseURL: URL? = nil,
        useSavedCredentials: Bool = true
    ) throws {
        self.configDir = configDir
        self.trustBundlePath = trustBundlePath
        self.useSavedCredentials = useSavedCredentials
        self.scopedCredentials = ScopedCredentials(
            url: baseURL.map(Self.trimTrailingSlash),
            username: username,
            password: password,
            realm: nil
        )
        self.baseURL = baseURL
        let initial = try createHandle(url: baseURL, credentials: nil)
        self.scopedCredentials = ScopedCredentials(
            url: baseURL.map(Self.trimTrailingSlash),
            username: initial.user,
            password: initial.password,
            realm: initial.realm
        )
        handle = initial.handle
    }

    deinit {
        if let h = swapActiveHandle(nil) { csvn_context_destroy(h) }
    }

    /// 请求取消当前实例上**正在执行**的活动操作。
    ///
    /// - Note: 该方法仅作用于调用时刻已进入此实例串行队列并处于活动状态的单个操作（包括正在轮询等待写锁或正在执行底层 C 调用的活动操作）；
    ///   若当前无活动操作，或当前活动操作结束后启动后续排队操作，新操作会在 `beginOperation` 时重置底层取消标志而不会受影响。
    ///   若需精确取消尚未进入执行阶段的排队操作或特定异步调用，请直接取消对应的 Swift `Task`。
    public func requestCancel() {
        stateLock.withLock {
            activeOperation?.isCancelled = true
            if let h = _handle {
                csvn_request_cancel(h)
            }
        }
    }

    private func beginOperation(_ op: OperationCancelState) -> Bool {
        stateLock.withLock {
            if op.isCancelled {
                return false
            }
            activeOperation = op
            if let h = _handle {
                csvn_clear_cancel(h)
            }
            return true
        }
    }

    private func cancelOperation(_ op: OperationCancelState) {
        stateLock.withLock {
            guard !op.isCancelled else { return }
            op.isCancelled = true
            if activeOperation === op, let h = _handle {
                csvn_request_cancel(h)
            }
        }
    }

    private func finishOperation(_ op: OperationCancelState) {
        stateLock.withLock {
            if activeOperation === op {
                activeOperation = nil
            }
            if let h = _handle {
                csvn_clear_cancel(h)
            }
        }
    }

    private func swapActiveHandle(_ newHandle: OpaquePointer?) -> OpaquePointer? {
        stateLock.withLock {
            let previous = _handle
            if let previous {
                csvn_clear_cancel(previous)
            }
            _handle = newHandle
            if let newHandle {
                if activeOperation?.isCancelled == true {
                    csvn_request_cancel(newHandle)
                } else {
                    csvn_clear_cancel(newHandle)
                }
            }
            return previous
        }
    }

    private func checkActiveCancellation() throws {
        let cancelled = stateLock.withLock {
            activeOperation?.isCancelled == true || (_handle.map { csvn_is_cancelled($0) != 0 } ?? false)
        }
        if cancelled {
            throw CancellationError()
        }
    }

    private func createHandle(url: URL?, credentials: Credentials?) throws
        -> (handle: OpaquePointer, user: String?, password: String?, realm: String?) {
        if let url, url.password != nil || (url.user != nil && url.scheme?.lowercased() != "svn+ssh") {
            throw VCSError.invalidArgument("请通过独立参数传递凭据")
        }
        var user = scopedCredentials.username
        var secret = scopedCredentials.password
        var realm = scopedCredentials.realm
        if let url, let credentialURL = scopedCredentials.url {
            if Self.trimTrailingSlash(credentialURL) != Self.trimTrailingSlash(url) {
                user = nil
                secret = nil
                realm = nil
            }
        }
        switch credentials?.kind {
        case .usernamePassword(let suppliedUser, let suppliedPassword):
            user = suppliedUser
            secret = suppliedPassword
            realm = nil
        case .keychain(let service, let account):
            guard let url, let saved = try KeychainStore.loadReference(service: service, username: account, url: url) else {
                throw VCSError.authenticationFailed("该仓库没有对应的钥匙串凭据")
            }
            user = account
            secret = saved.password
            realm = saved.realm
        case nil:
            if let url, useSavedCredentials, let user, secret == nil,
               let saved = try KeychainStore.load(url: url, username: user) {
                secret = saved.password
                realm = saved.realm
            }
        }

        let origin = url.flatMap(SVNOrigin.init)
        let pin = origin.flatMap { $0.scheme == "https" ? TrustStore.shared.pinnedCertificate(for: $0) : nil }
        var errbuf = [CChar](repeating: 0, count: 2048)
        let strings = [user, secret, configDir, origin?.authPrefix, realm, pin,
                       origin?.scheme == "https" ? trustBundlePath : nil, origin?.host]
        let cStrings = strings.map { value in value.flatMap { strdup($0) } }
        defer {
            for value in cStrings {
                if let value {
                    let len = strlen(value)
                    if len > 0 {
                        _ = memset_s(value, len, 0, len)
                    }
                    free(value)
                }
            }
        }
        guard let h = csvn_context_create(cStrings[0], cStrings[1], cStrings[2], cStrings[3],
                                          cStrings[4], cStrings[5], cStrings[6], cStrings[7],
                                          &errbuf, Int32(errbuf.count)) else {
            throw VCSError.underlying("无法初始化 SVN 上下文：\(String(cString: errbuf))")
        }
        return (h, user, secret, realm)
    }

    /// 仅保存已成功连接且实际完成口令认证的 HTTPS 凭据。
    @discardableResult
    public func rememberPassword() async throws -> Bool {
        try await perform {
            guard let connection = self.rememberedConnection else { return false }
            try KeychainStore.save(url: connection.url, username: connection.username,
                                   password: connection.password, realm: connection.realm)
            return true
        }
    }

    // MARK: 基础设施

    /// 在私有队列上执行一段阻塞的 libsvn 调用，并将 Swift Task 取消桥接到底层 `csvn_request_cancel`。
    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancelState = OperationCancelState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                queue.async {
                    guard self.beginOperation(cancelState) else {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let result = try body()
                        self.finishOperation(cancelState)
                        cont.resume(returning: result)
                    } catch {
                        self.finishOperation(cancelState)
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancelOperation(cancelState)
        }
    }

    // 跨实例串行化进程内工作副本写操作，libsvn 继续负责磁盘工作副本锁。
    private static let workingCopyWriteLock = NSLock()

    private func performWrite<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await perform {
            try self.checkActiveCancellation()
            while !Self.workingCopyWriteLock.lock(before: Date(timeIntervalSinceNow: 0.01)) {
                try self.checkActiveCancellation()
            }
            defer { Self.workingCopyWriteLock.unlock() }
            try self.checkActiveCancellation()
            return try body()
        }
    }

    /// 把 shim 的返回码翻译成统一的 VCSError。
    private func check(_ rc: Int32) throws {
        guard rc != 0 else { return }
        let msg = handle.map { String(cString: csvn_last_error($0)) } ?? ""
        switch rc {
        case -1:
            throw VCSError.authenticationFailed(msg)
        case -2:
            throw VCSError.transport(msg)
        case -4:
            throw VCSError.invalidArgument(msg)
        case -7:
            throw CancellationError()
        case -100:
            throw VCSError.underlying(msg)
        default:
            throw VCSError.underlying(msg.isEmpty ? "未知错误（码 \(rc)）" : msg)
        }
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let h = handle else { throw VCSError.underlying("SVN 上下文已释放") }
        return h
    }

    /// 把仓库内相对路径拼成完整 URL（逐段追加，避免無尾斜杠时覆盖最后一段路径，并正确处理中文/空格编码）。
    private func url(for path: String?) throws -> URL {
        guard let base = baseURL else { throw VCSError.underlying("尚未连接仓库") }
        guard let path, !path.isEmpty else { return base }
        var result = base
        for component in path.split(separator: "/") where !component.isEmpty {
            result = result.appendingPathComponent(String(component))
        }
        return result
    }

    /// 根据仓库根 URL 与以 `/` 开头的仓库内路径拼出完整文件 URL。
    private static func buildRepoURL(root: URL, repoRelativePath: String) -> URL {
        var result = root
        for component in repoRelativePath.split(separator: "/") where !component.isEmpty {
            result = result.appendingPathComponent(String(component))
        }
        return result
    }

    private static func trimTrailingSlash(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.count > 1 && s.hasSuffix("/") && !s.hasSuffix("://") {
            s.removeLast()
        }
        return URL(string: s) ?? url
    }

    /// 在队列内获取或推导仓库根 URL（必须在 queue 内调用）。
    private func resolveRootURLSync(handle h: OpaquePointer, explicit: URL? = nil) throws -> URL {
        if let explicit {
            let normExplicit = Self.trimTrailingSlash(explicit)
            let uStr = normExplicit.absoluteString
            if let cached = self.rootURL {
                let cachedNorm = Self.trimTrailingSlash(cached)
                let cachedStr = cachedNorm.absoluteString
                if uStr == cachedStr || uStr.hasPrefix(cachedStr + "/") {
                    return cachedNorm
                }
            }
            return normExplicit
        }

        if let cached = self.rootURL {
            let cachedNorm = Self.trimTrailingSlash(cached)
            let cachedStr = cachedNorm.absoluteString
            if let base = self.baseURL {
                let uStr = Self.trimTrailingSlash(base).absoluteString
                if uStr == cachedStr || uStr.hasPrefix(cachedStr + "/") {
                    return cachedNorm
                }
            } else {
                return cachedNorm
            }
        }

        if let probeURL = self.baseURL {
            var rootBuf = [CChar](repeating: 0, count: 2048)
            let rc = probeURL.absoluteString.withCString { u in
                csvn_get_repos_root(h, u, &rootBuf, Int32(rootBuf.count))
            }
            if rc == -7 {
                try self.check(rc)
            }
            if rc == 0 {
                let s = String(cString: rootBuf)
                if !s.isEmpty, let resolved = URL(string: s) {
                    let normResolved = Self.trimTrailingSlash(resolved)
                    self.rootURL = normResolved
                    return normResolved
                }
            }
            return Self.trimTrailingSlash(probeURL)
        }
        throw VCSError.underlying("尚未连接仓库")
    }

    /// 工作副本内的绝对路径。
    private func localPath(_ workingCopy: URL, _ relative: String) -> String {
        if relative == "." || relative.isEmpty {
            return workingCopy.path
        }
        return relative.hasPrefix("/") ? relative : workingCopy.appendingPathComponent(relative).path
    }

    /// 离线读取本地工作副本所关联的远端仓库 URL（直接查询 `.svn/wc.db`）。
    public static func workingCopyURL(at workingCopy: URL) -> URL? {
        var errbuf = [CChar](repeating: 0, count: 512)
        guard let ctx = csvn_context_create(nil, nil, nil, nil, nil, nil, nil, nil, &errbuf, Int32(errbuf.count)) else {
            return nil
        }
        defer { csvn_context_destroy(ctx) }
        var out = [CChar](repeating: 0, count: 2048)
        let rc = workingCopy.path.withCString { p in
            csvn_wc_url(ctx, p, &out, Int32(out.count))
        }
        guard rc == 0 else { return nil }
        let str = String(cString: out)
        guard !str.isEmpty, let clean = SVNURLSanitizer.sanitizeForPersistence(str) else {
            return nil
        }
        return URL(string: clean)
    }

    // MARK: 1. 连接

    public func connect(to url: URL, credentials: Credentials?) async throws -> RepositoryInfo {
        try await perform {
            self.rememberedConnection = nil
            let candidate = try self.createHandle(url: url, credentials: credentials)
            let h = candidate.handle
            let previous = self.swapActiveHandle(h)
            var connected = false
            defer {
                if connected {
                    if let previous { csvn_context_destroy(previous) }
                } else {
                    _ = self.swapActiveHandle(previous)
                    csvn_context_destroy(h)
                }
            }
            try self.checkActiveCancellation()
            var uuid = [CChar](repeating: 0, count: 256)
            var rev: Int32 = 0
            let rc = url.absoluteString.withCString { u in
                csvn_connect(h, u, &uuid, Int32(uuid.count), &rev)
            }
            try self.check(rc)

            var rootBuf = [CChar](repeating: 0, count: 2048)
            let rootRC = url.absoluteString.withCString { u in
                csvn_get_repos_root(h, u, &rootBuf, Int32(rootBuf.count))
            }
            if rootRC == -7 {
                try self.check(rootRC)
            }
            try self.checkActiveCancellation()

            let resolvedRootURL: URL?
            if rootRC == 0 {
                let rootStr = String(cString: rootBuf)
                if !rootStr.isEmpty, let resolved = URL(string: rootStr) {
                    resolvedRootURL = Self.trimTrailingSlash(resolved)
                } else {
                    resolvedRootURL = nil
                }
            } else {
                resolvedRootURL = nil
            }
            self.baseURL = Self.trimTrailingSlash(url)
            self.rootURL = resolvedRootURL

            let authRealm: String? = {
                guard let value = csvn_auth_realm(h), value.pointee != 0 else { return nil }
                return String(cString: value)
            }()
            if KeychainStore.service(for: url) != nil,
               let username = candidate.user, let password = candidate.password,
               let authRealm {
                self.rememberedConnection = (url, username, password, authRealm)
            }
            self.scopedCredentials = ScopedCredentials(
                url: Self.trimTrailingSlash(url),
                username: candidate.user,
                password: candidate.password,
                realm: candidate.realm ?? authRealm
            )
            connected = true
            return RepositoryInfo(
                url: url,
                uuid: String(cString: uuid).isEmpty ? nil : String(cString: uuid),
                revision: Int(rev),
                youngestRevision: Int(rev),
                rootURL: resolvedRootURL ?? Self.trimTrailingSlash(url)
            )
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let handle = self.swapActiveHandle(nil) {
                    csvn_context_destroy(handle)
                }
                self.rememberedConnection = nil
                self.baseURL = nil
                self.rootURL = nil
                cont.resume()
            }
        }
    }

    // MARK: 2. 浏览

    public func browse(path: String?) async throws -> [RepositoryEntry] {
        let target = try url(for: path)
        let cleanPrefix = (path ?? "")
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")

        return try await perform {
            let h = try self.requireHandle()
            var entries: UnsafeMutablePointer<csvn_entry>? = nil
            var count: Int32 = 0
            let rc = target.absoluteString.withCString { u in
                csvn_list(h, u, &entries, &count)
            }
            try self.check(rc)
            defer { csvn_free_entries(entries, count) }
            guard let entries else { return [] }

            var result: [RepositoryEntry] = []
            result.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                var e = entries.advanced(by: i).pointee
                let p = String(cString: csvn_entry_path_p(&e))
                let name = String(cString: csvn_entry_name_p(&e))
                let author = String(cString: csvn_entry_author_p(&e))
                if p.isEmpty && name.isEmpty { continue }

                let entryName = name.isEmpty
                    ? (p.split(separator: "/").last.map(String.init) ?? p)
                    : name
                let relPath = p.isEmpty ? entryName : p
                let fullPath = cleanPrefix.isEmpty ? relPath : "\(cleanPrefix)/\(relPath)"

                let kind: RepositoryEntry.Kind
                switch e.kind {
                case 0x64: kind = .directory     // 'd'
                case 0x6C: kind = .symlink       // 'l'
                default:   kind = .file
                }
                result.append(
                    RepositoryEntry(
                        id: fullPath,
                        path: fullPath,
                        name: entryName,
                        kind: kind,
                        revision: Int(e.revision),
                        size: e.size >= 0 ? e.size : nil,
                        author: author.isEmpty ? nil : author,
                        lastModified: e.timestamp > 0
                            ? Date(timeIntervalSince1970: Double(e.timestamp) / 1_000_000)
                            : nil
                    )
                )
            }
            return result
        }
    }

    // MARK: 3. 检出

    @discardableResult
    public func checkout(path: String?, to destination: URL, revision: Int?) async throws -> URL {
        let nativeRevision = try Self.nativeInteger(revision ?? 0, field: "修订号")
        let target = try url(for: path)
        return try await performWrite {
            let h = try self.requireHandle()
            var rev: Int32 = 0
            let dest = destination.path
            let rc = target.absoluteString.withCString { u in
                dest.withCString { d in
                    csvn_checkout(h, u, d, nativeRevision, &rev)
                }
            }
            try self.check(rc)
            return destination
        }
    }

    // MARK: 4. 同步

    public func update(
        workingCopy: URL,
        revision: Int?,
        progress: (@Sendable (VCSTaskProgress) -> Void)?
    ) async throws -> UpdateResult {
        let nativeRevision = try Self.nativeInteger(revision ?? 0, field: "修订号")
        return try await performWrite {
            let h = try self.requireHandle()
            let wc = workingCopy.path
            progress?(VCSTaskProgress(phase: "正在同步工作副本", completed: 0, total: 1, currentPath: wc))
            var rev: Int32 = 0
            var updated: Int32 = 0
            var added: Int32 = 0
            var deleted: Int32 = 0
            var conflicts: UnsafeMutablePointer<CChar>? = nil
            var conflictCount: Int32 = 0

            let rc = wc.withCString { p in
                csvn_update(h, p, nativeRevision, &rev, &updated, &added, &deleted,
                            &conflicts, &conflictCount)
            }
            try self.check(rc)
            defer { if let conflicts { csvn_free_string(conflicts) } }
            progress?(VCSTaskProgress(phase: "同步完成", completed: 1, total: 1, currentPath: wc))

            let list = conflicts.map { String(cString: $0) }?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []

            return UpdateResult(
                revision: Int(rev),
                updatedCount: Int(updated),
                addedCount: Int(added),
                deletedCount: Int(deleted),
                conflicts: list
            )
        }
    }

    // MARK: 5. 状态

    public func status(of workingCopy: URL) async throws -> [WorkingCopyStatus] {
        try await perform { try self.readStatus(workingCopy.standardizedFileURL.resolvingSymlinksInPath().path) }
    }

    private func readStatus(_ root: String) throws -> [WorkingCopyStatus] {
        let h = try requireHandle()
        var items: UnsafeMutablePointer<csvn_status_item>?
        var count: Int32 = 0
        try check(root.withCString { csvn_status(h, $0, &items, &count) })
        defer { csvn_free_status(items, count) }
        guard let items else { return [] }

        func relative(_ path: String) -> String? {
            if path == root { return "." }
            guard path.hasPrefix(root + "/") else { return nil }
            return String(path.dropFirst(root.count + 1))
        }
        return (0..<Int(count)).compactMap { i in
            var s = items[i]
            let path = String(cString: csvn_status_path_p(&s))
            guard let rel = relative(path) else { return nil }
            let kind = Self.mapStatusKind(s.kind)
            if rel == "." && kind == .normal { return nil }
            let lockOwner = String(cString: csvn_status_lock_p(&s))
            let conflictKinds = ConflictKind.allCases.enumerated().compactMap { index, kind in
                s.conflict_kinds & (1 << index) != 0 ? kind : nil
            }
            let resolutions = ConflictResolution.allCases.enumerated().compactMap { index, strategy in
                s.resolutions & (1 << index) != 0 ? strategy : nil
            }
            return WorkingCopyStatus(
                id: rel, path: rel, name: rel == "." ? "." : String(cString: csvn_status_name_p(&s)),
                kind: kind, baseRevision: Int(s.base_revision),
                workingRevision: s.working_revision >= 0 ? Int(s.working_revision) : nil,
                isDirectory: s.is_directory != 0, lockOwner: lockOwner.isEmpty ? nil : lockOwner,
                movedFrom: relative(String(cString: csvn_status_moved_from_p(&s))),
                movedTo: relative(String(cString: csvn_status_moved_to_p(&s))),
                conflictKinds: Set(conflictKinds), resolutions: Set(resolutions),
                mergeInfoChanged: s.mergeinfo_changed != 0,
                movedDestinationModified: s.moved_destination_modified != 0
            )
        }
    }

    private static func mapStatusKind(_ c: CChar) -> WorkingCopyStatus.Kind {
        switch c {
        case 0x20: return .normal          // ' '
        case 0x41: return .added           // 'A'
        case 0x4D: return .modified        // 'M'
        case 0x44: return .deleted         // 'D'
        case 0x52: return .replaced        // 'R'
        case 0x43: return .conflicted      // 'C'
        case 0x21: return .missing         // '!'
        case 0x3F: return .unversioned     // '?'
        case 0x49: return .ignored         // 'I'
        case 0x7E: return .obstructed      // '~'
        case 0x58: return .unknown("外部定义")
        case 0x4F: return .unknown("缺失")
        default:   return .unknown(String(c))
        }
    }

    // MARK: 6. 差异

    public static let binaryExtensions: Set<String> = [
        "jar", "war", "ear", "class",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "tiff", "tif",
        "pdf", "xls", "xlsx", "doc", "docx", "ppt", "pptx",
        "dylib", "so", "a", "o", "dll", "exe", "bin", "dat",
        "db", "sqlite", "sqlite3",
        "mp3", "mp4", "mov", "avi", "wav", "flac",
        "woff", "woff2", "ttf", "otf", "eot",
        "pyc", "keystore", "jks", "p12", "pfx"
    ]

    public static func isKnownBinaryPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && binaryExtensions.contains(ext)
    }

    public static func looksBinaryData(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// 只有明确截断的读取才允许丢弃末尾不完整的字符。
    public static func decodeText(_ data: Data, isTruncated: Bool = false) -> String? {
        if looksBinaryData(data) { return nil }
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        func decode(_ bytes: Data) -> String? {
            String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: gbEncoding)
        }
        if let text = decode(data) { return text }

        // 差异的 UTF-8 标头与正文有时来自不同的编码。
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var decoded: [String] = []
        for (index, line) in lines.enumerated() {
            if let text = decode(Data(line)) {
                decoded.append(text)
            } else if isTruncated, index == lines.count - 1,
                      let recovered = (1...3).lazy.filter({ $0 <= line.count })
                          .compactMap({ decode(Data(line.dropLast($0))) }).first {
                decoded.append(recovered)
            } else {
                return nil
            }
        }
        return decoded.joined(separator: "\n")
    }

    private static func normalizeLineEndings(_ s: String) -> String {
        if !s.utf8.contains(0x0D) { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func splitNormalizedLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        let norm = normalizeLineEndings(content)
        var lines = norm.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if norm.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// 合成全新增文件的 hunk。
    public static func synthesizeAdded(_ content: String) -> [FileDiff.Hunk] {
        let lines = splitNormalizedLines(content)
        guard !lines.isEmpty else { return [] }
        let hunkLines = lines.enumerated().map { idx, text in
            FileDiff.Hunk.Line(kind: .addition, text: text, oldLine: nil, newLine: idx + 1)
        }
        return [
            FileDiff.Hunk(
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: lines.count,
                header: "@@ -0,0 +1,\(lines.count) @@",
                lines: hunkLines
            )
        ]
    }

    /// 合成全删除文件的 hunk。
    public static func synthesizeDeleted(_ content: String) -> [FileDiff.Hunk] {
        let lines = splitNormalizedLines(content)
        guard !lines.isEmpty else { return [] }
        let hunkLines = lines.enumerated().map { idx, text in
            FileDiff.Hunk.Line(kind: .deletion, text: text, oldLine: idx + 1, newLine: nil)
        }
        return [
            FileDiff.Hunk(
                oldStart: 1,
                oldCount: lines.count,
                newStart: 0,
                newCount: 0,
                header: "@@ -1,\(lines.count) +0,0 @@",
                lines: hunkLines
            )
        ]
    }

    /// 解码多文件 unified diff 字节流（严禁回退到 `String(cString:)`，防止遇到 NUL 字节截断后续所有文件）。
    /// 若整体 `decodeText` 失败，则按 `Index: ` 段切分逐段解码，单段失败时回退为 `String(decoding: as: UTF8.self)`。
    public static func decodeMultiFileDiffData(_ rawData: Data) -> String {
        decodeDiffSections(rawData).text
    }

    private static func decodeDiffSections(_ rawData: Data, isTruncated: Bool = false) -> (text: String, lossy: Bool) {
        if rawData.isEmpty { return ("", false) }
        if let whole = decodeText(rawData, isTruncated: isTruncated) {
            return (whole, false)
        }
        let lineSlices = rawData.split(separator: 0x0A, omittingEmptySubsequences: false)
        let indexPrefix = Array("Index: ".utf8)
        var sectionsData: [Data] = []
        var currentLines: [Data] = []

        func flushSection() {
            guard !currentLines.isEmpty else { return }
            var sec = Data()
            for (idx, line) in currentLines.enumerated() {
                if idx > 0 { sec.append(0x0A) }
                sec.append(line)
            }
            sectionsData.append(sec)
            currentLines.removeAll(keepingCapacity: true)
        }

        for slice in lineSlices {
            if slice.starts(with: indexPrefix) {
                flushSection()
            }
            currentLines.append(Data(slice))
        }
        flushSection()

        var lossy = false
        let decodedSections = sectionsData.enumerated().map { idx, section in
            let sectionTruncated = isTruncated && idx == sectionsData.count - 1
            if let decoded = decodeText(section, isTruncated: sectionTruncated) { return decoded }
            lossy = true
            return String(decoding: section, as: UTF8.self)
        }
        return (decodedSections.joined(separator: "\n"), lossy)
    }

    /// 仅在进入首个 `@@` hunk 之前的 diff 头部行中检查固定格式的二进制标记，避免把包含 `"Binary file"` 的源码改动行误判为二进制。
    public static func hasBinaryDiffHeader(_ diffSection: String) -> Bool {
        for line in splitNormalizedLines(diffSection) {
            if line.hasPrefix("@@") {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Cannot display: file marked as a binary type")
                || trimmed.hasPrefix("Binary files ")
                || trimmed.hasPrefix("GIT binary patch") {
                return true
            }
        }
        return false
    }

    private func propertyChanges(from old: [String: Data], to new: [String: Data]) -> [PropertyChange] {
        Set(old.keys).union(new.keys).sorted().compactMap { name in
            guard old[name] != new[name] else { return nil }
            return PropertyChange(name: name, oldValue: old[name], newValue: new[name])
        }
    }

    private func propertySnapshot(_ read: (UnsafeMutablePointer<UnsafeMutablePointer<csvn_property>?>,
                                          UnsafeMutablePointer<Int32>) -> Int32) throws -> [String: Data] {
        var rows: UnsafeMutablePointer<csvn_property>?
        var count: Int32 = 0
        defer { csvn_free_properties(rows, count) }
        try check(read(&rows, &count))
        guard let rows else { return [:] }
        return Dictionary(uniqueKeysWithValues: (0..<Int(count)).map { index in
            let row = rows[index]
            return (String(cString: row.name), row.data.map { Data(bytes: $0, count: row.length) } ?? Data())
        })
    }

    private func withProperties(_ changes: [PropertyChange], in diff: FileDiff) -> FileDiff {
        FileDiff(id: diff.id, path: diff.path, localPath: diff.localPath, isBinary: diff.isBinary,
                 hunks: diff.hunks, isTruncated: diff.isTruncated,
                 statusNotice: diff.statusNotice, propertyChanges: changes)
    }

    public func diff(workingCopy: URL, paths: [String]) async throws -> [FileDiff] {
        try await diff(workingCopy: workingCopy, paths: paths, maxBytes: 32 * 1024 * 1024)
    }

    public func diff(workingCopy: URL, paths: [String], maxBytes: Int) async throws -> [FileDiff] {
        let defaultTotal = max(64 * 1024 * 1024, maxBytes > 0 ? min(maxBytes * 2, 128 * 1024 * 1024) : 64 * 1024 * 1024)
        return try await diff(
            workingCopy: workingCopy,
            paths: paths,
            maxBytes: maxBytes,
            totalMaxBytes: defaultTotal,
            maxSections: 4096
        )
    }

    public func diff(
        workingCopy: URL,
        paths: [String],
        maxBytes: Int,
        totalMaxBytes: Int,
        maxSections: Int
    ) async throws -> [FileDiff] {
        guard maxBytes >= 0 else { throw VCSError.invalidArgument("差异字节上限不能为负数") }
        guard totalMaxBytes >= 0 else { throw VCSError.invalidArgument("差异总字节上限不能为负数") }
        guard maxSections >= 0 else { throw VCSError.invalidArgument("差异分段上限不能为负数") }
        return try await perform {
            let h = try self.requireHandle()
            let wcPath = try self.writeRoot(workingCopy)
            let cleanWC = wcPath.hasSuffix("/") ? String(wcPath.dropLast()) : wcPath
            let targets = paths.isEmpty ? [cleanWC] : try paths.map {
                try self.writePath($0, root: cleanWC, originalRoot: workingCopy.standardizedFileURL.path)
            }

            let wcStatuses = try self.readStatus(cleanWC)
            let structuralDirs: [String] = wcStatuses
                .filter { $0.isDirectory && ($0.kind == .added || $0.kind == .replaced || $0.kind == .deleted) }
                .map { $0.path == "." ? cleanWC : cleanWC + "/" + $0.path }
                .sorted { $0.count < $1.count }

            func effectiveDiffRoot(for target: String) -> String {
                guard target != cleanWC else { return cleanWC }
                if let ancestor = structuralDirs.first(where: { target.hasPrefix($0 + "/") }) {
                    return ancestor
                }
                return target
            }

            var diffGroups: [(root: String, filters: [String])] = []
            for t in targets {
                let root = effectiveDiffRoot(for: t)
                if let idx = diffGroups.firstIndex(where: { root == $0.root || root.hasPrefix($0.root + "/") }) {
                    if !diffGroups[idx].filters.contains(t) {
                        diffGroups[idx].filters.append(t)
                    }
                } else {
                    var mergedFilters: [String] = []
                    var remainingGroups: [(root: String, filters: [String])] = []
                    for existing in diffGroups {
                        if existing.root == root || existing.root.hasPrefix(root + "/") {
                            for f in existing.filters where !mergedFilters.contains(f) {
                                mergedFilters.append(f)
                            }
                        } else {
                            remainingGroups.append(existing)
                        }
                    }
                    if !mergedFilters.contains(t) {
                        mergedFilters.append(t)
                    }
                    remainingGroups.append((root: root, filters: mergedFilters))
                    diffGroups = remainingGroups
                }
            }

            var out: [FileDiff] = []
            var indexByPath: [String: Int] = [:]
            let effectiveMaxSections = maxSections > 0 ? maxSections : 4096
            var remainingTotalBytes = totalMaxBytes > 0 ? totalMaxBytes : (32 * 1024 * 1024)
            var remainingSections = effectiveMaxSections
            var budgetExhausted = false

            for group in diffGroups {
                try self.checkActiveCancellation()
                if remainingTotalBytes <= 0 || remainingSections <= 0 {
                    budgetExhausted = true
                    break
                }
                var sections: UnsafeMutablePointer<csvn_diff_section>? = nil
                var count: Int32 = 0
                var groupTotalTruncated: Int32 = 0
                let sectionCap = Int32(clamping: remainingSections)
                let rc = group.root.withCString { p in
                    cleanWC.withCString { wcC in
                        csvn_diff_sections_ex(
                            h,
                            p,
                            wcC,
                            maxBytes,
                            remainingTotalBytes,
                            sectionCap,
                            &sections,
                            &count,
                            &groupTotalTruncated
                        )
                    }
                }
                try self.check(rc)
                defer { csvn_free_diff_sections(sections, count) }
                if let sections, count > 0 {
                    for i in 0..<Int(count) {
                        let sec = sections[i]
                        let consumedBytes = max(0, Int(sec.length))
                        remainingTotalBytes = max(0, remainingTotalBytes - consumedBytes)
                        remainingSections = max(0, remainingSections - 1)

                        let rawPath = sec.path.map { String(cString: $0) } ?? group.root
                        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        var rel = trimmedPath
                        if rel.hasPrefix(cleanWC + "/") {
                            rel = String(rel.dropFirst(cleanWC.count + 1))
                        } else if rel == cleanWC {
                            rel = "."
                        }
                        let absPath = trimmedPath.hasPrefix("/")
                            ? trimmedPath
                            : (rel == "." ? cleanWC : cleanWC + "/" + rel)

                        let matchesFilter = group.filters.contains { filter in
                            filter == cleanWC || absPath == filter || absPath.hasPrefix(filter + "/")
                        }
                        guard matchesFilter else { continue }

                        let isTrunc = sec.truncated != 0
                        let data = (sec.text != nil && sec.length > 0)
                            ? Data(bytes: sec.text!, count: Int(sec.length))
                            : Data()
                        let decoded = data.isEmpty ? "" : Self.decodeText(data, isTruncated: isTrunc)
                        let lossy = !data.isEmpty && decoded == nil
                        let body = decoded ?? String(decoding: data, as: UTF8.self)
                        let hunks = body.isEmpty ? [] : Self.parseUnifiedDiff(body)
                        let isBin = Self.hasBinaryDiffHeader(body)
                            || data.contains(0)
                            || Self.isKnownBinaryPath(absPath)
                        if hunks.isEmpty && !isBin && !isTrunc { continue }

                        let notice: String? = isBin
                            ? "二进制文件，不支持文本差异预览"
                            : (lossy ? "部分差异无法完整解码" : nil)

                        if let existingIdx = indexByPath[rel] {
                            let prev = out[existingIdx]
                            let mergedBin = prev.isBinary || isBin
                            out[existingIdx] = FileDiff(
                                id: prev.id,
                                path: prev.path,
                                localPath: prev.localPath,
                                isBinary: mergedBin,
                                hunks: mergedBin ? [] : (prev.hunks + hunks),
                                isTruncated: prev.isTruncated || isTrunc,
                                statusNotice: prev.statusNotice ?? notice,
                                propertyChanges: prev.propertyChanges
                            )
                        } else {
                            indexByPath[rel] = out.count
                            out.append(
                                FileDiff(
                                    id: rel,
                                    path: rel,
                                    localPath: URL(fileURLWithPath: absPath),
                                    isBinary: isBin,
                                    hunks: isBin ? [] : hunks,
                                    isTruncated: isTrunc,
                                    statusNotice: notice
                                )
                            )
                        }
                    }
                }

                if groupTotalTruncated != 0 {
                    budgetExhausted = true
                    break
                }
            }

            if budgetExhausted {
                let budgetNotice = "差异输出已达到预算上限，部分内容或后续文件未展开"
                if !out.isEmpty {
                    let lastIdx = out.count - 1
                    let last = out[lastIdx]
                    let combinedNotice: String
                    if let existing = last.statusNotice, !existing.isEmpty {
                        combinedNotice = existing.contains(budgetNotice) ? existing : "\(existing)；\(budgetNotice)"
                    } else {
                        combinedNotice = budgetNotice
                    }
                    out[lastIdx] = FileDiff(
                        id: last.id,
                        path: last.path,
                        localPath: last.localPath,
                        isBinary: last.isBinary,
                        hunks: last.hunks,
                        isTruncated: true,
                        statusNotice: combinedNotice,
                        propertyChanges: last.propertyChanges
                    )
                } else {
                    let fallbackAbs = targets.first ?? cleanWC
                    let fallbackRel = fallbackAbs == cleanWC
                        ? "."
                        : (fallbackAbs.hasPrefix(cleanWC + "/")
                            ? String(fallbackAbs.dropFirst(cleanWC.count + 1))
                            : fallbackAbs)
                    indexByPath[fallbackRel] = 0
                    out.append(
                        FileDiff(
                            id: fallbackRel,
                            path: fallbackRel,
                            localPath: URL(fileURLWithPath: fallbackAbs),
                            isBinary: false,
                            hunks: [],
                            isTruncated: true,
                            statusNotice: budgetNotice
                        )
                    )
                }
            }

            var seen: Set<String> = []
            for status in wcStatuses where status.kind.isPendingChange {
                try self.checkActiveCancellation()
                let path = status.path == "." ? cleanWC : cleanWC + "/" + status.path
                let matchesTarget = targets.contains { t in
                    t == cleanWC || path == t || path.hasPrefix(t + "/")
                }
                guard matchesTarget, seen.insert(path).inserted else { continue }
                let relative = path == cleanWC ? "." : String(path.dropFirst(cleanWC.count + 1))
                if indexByPath[relative] == nil && out.count >= effectiveMaxSections {
                    continue
                }
                let old = try self.propertySnapshot {
                    csvn_wc_property_snapshot(h, path, 1, status.kind == .replaced ? 1 : 0, $0, $1)
                }
                let new = try self.propertySnapshot { csvn_wc_property_snapshot(h, path, 0, 0, $0, $1) }
                let changes = self.propertyChanges(from: old, to: new)
                guard !changes.isEmpty else { continue }
                if let index = indexByPath[relative] {
                    out[index] = self.withProperties(changes, in: out[index])
                } else {
                    indexByPath[relative] = out.count
                    out.append(FileDiff(id: relative, path: relative,
                                        localPath: URL(fileURLWithPath: path),
                                        isBinary: Self.isKnownBinaryPath(path), hunks: [],
                                        propertyChanges: changes))
                }
            }
            return out
        }
    }

    /// 计算某次修订中单个变更文件的差异（自动处理 M/R/A/D、copyfrom、二进制跳过与大文件截断）。
    public func diffFile(
        revision: Int,
        change: ChangedPath,
        repoRootURL: URL? = nil,
        maxBytes: Int = 2 * 1024 * 1024
    ) async throws -> FileDiff {
        let nativeRevision = try Self.nativeInteger(revision, field: "修订号", minimum: 1)
        let nativeCopyRevision = try change.copyFromRevision.map {
            try Self.nativeInteger($0, field: "复制来源修订号", minimum: 1)
        }
        guard maxBytes >= 0 else { throw VCSError.invalidArgument("差异字节上限不能为负数") }
        let content = try await diffFileContent(revision: revision, nativeRevision: nativeRevision,
                                                nativeCopyRevision: nativeCopyRevision,
                                                change: change, repoRootURL: repoRootURL, maxBytes: maxBytes)
        let changes = try await perform {
            let h = try self.requireHandle()
            let root = try self.resolveRootURLSync(handle: h, explicit: repoRootURL)
            let target = Self.buildRepoURL(root: root, repoRelativePath: change.path)
            func snapshot(_ url: URL, _ revision: Int32) throws -> [String: Data] {
                try self.propertySnapshot {
                    csvn_properties(h, nil, url.absoluteString, nil, revision, revision, 0, $0, $1)
                }
            }
            let old: [String: Data]
            if (change.action == .added || change.action == .replaced),
               let source = change.copyFromPath, let copyRev32 = nativeCopyRevision {
                old = try snapshot(Self.buildRepoURL(root: root, repoRelativePath: source), copyRev32)
            } else if change.action == .added {
                old = [:]
            } else {
                old = try snapshot(target, nativeRevision - 1)
            }
            let new = change.action == .deleted ? [:] : try snapshot(target, nativeRevision)
            return self.propertyChanges(from: old, to: new)
        }
        return withProperties(changes, in: content)
    }

    private func diffFileContent(revision: Int, nativeRevision: Int32, nativeCopyRevision: Int32?, change: ChangedPath,
                                 repoRootURL: URL?, maxBytes: Int) async throws -> FileDiff {
        if change.kind == .directory {
            let fallbackURL = (repoRootURL ?? self.rootURL ?? self.baseURL)
                .map { Self.buildRepoURL(root: $0, repoRelativePath: change.path) }
                ?? URL(fileURLWithPath: change.path)
            return FileDiff(
                id: change.path,
                path: change.path,
                localPath: fallbackURL,
                isBinary: false,
                hunks: [],
                isTruncated: false,
                statusNotice: "目录变更"
            )
        }

        if Self.isKnownBinaryPath(change.path) {
            let fallbackURL = (repoRootURL ?? self.rootURL ?? self.baseURL)
                .map { Self.buildRepoURL(root: $0, repoRelativePath: change.path) }
                ?? URL(fileURLWithPath: change.path)
            let ext = (change.path as NSString).pathExtension.lowercased()
            return FileDiff(
                id: change.path,
                path: change.path,
                localPath: fallbackURL,
                isBinary: true,
                hunks: [],
                isTruncated: false,
                statusNotice: "二进制文件（.\(ext)），不支持文本差异预览"
            )
        }

        return try await perform {
            let h = try self.requireHandle()
            let root = try self.resolveRootURLSync(handle: h, explicit: repoRootURL)
            let targetURL = Self.buildRepoURL(root: root, repoRelativePath: change.path)

            func catContent(url: URL, rev: Int32) throws -> (data: Data, truncated: Bool)? {
                guard rev >= 0 else { return nil }
                var buf: UnsafeMutablePointer<CChar>? = nil
                var len: Int = 0
                var truncated: Int32 = 0
                let rc = url.absoluteString.withCString { u in
                    csvn_cat_capped(h, u, rev, maxBytes, &buf, &len, &truncated)
                }
                defer { if let buf { csvn_free_string(buf) } }
                if rc == -7 { try self.check(rc) }
                guard rc == 0, let buf else { return nil }
                return (Data(bytes: buf, count: max(0, len)), truncated != 0)
            }

            func makeDiffFromUnified(data: Data, truncated: Bool, emptyNotice: String?) -> FileDiff {
                if data.isEmpty {
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: [],
                        isTruncated: truncated,
                        statusNotice: emptyNotice
                    )
                }
                if Self.looksBinaryData(data) {
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: true,
                        hunks: [],
                        isTruncated: truncated,
                        statusNotice: "二进制文件，不支持文本差异预览"
                    )
                }
                let decoded = Self.decodeText(data, isTruncated: truncated)
                let text = decoded ?? String(decoding: data, as: UTF8.self)
                if Self.hasBinaryDiffHeader(text) {
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: true,
                        hunks: [],
                        isTruncated: truncated,
                        statusNotice: "二进制文件，不支持文本差异预览"
                    )
                }
                let hunks = Self.parseUnifiedDiff(text)
                return FileDiff(
                    id: change.path,
                    path: change.path,
                    localPath: targetURL,
                    isBinary: false,
                    hunks: hunks,
                    isTruncated: truncated,
                    statusNotice: decoded == nil ? "部分差异无法完整解码" : (hunks.isEmpty ? emptyNotice : nil)
                )
            }

            switch change.action {
            case .added:
                if let copyFrom = change.copyFromPath, !copyFrom.isEmpty,
                   let copyRev32 = nativeCopyRevision, copyRev32 > 0 {
                    let fromURL = Self.buildRepoURL(root: root, repoRelativePath: copyFrom)
                    var textPtr: UnsafeMutablePointer<CChar>? = nil
                    var len: Int = 0
                    var truncated: Int32 = 0
                    let rc = fromURL.absoluteString.withCString { u1 in
                        targetURL.absoluteString.withCString { u2 in
                            csvn_diff_urls(h, u1, copyRev32, u2, nativeRevision, maxBytes, &textPtr, &len, &truncated)
                        }
                    }
                    defer { if let textPtr { csvn_free_string(textPtr) } }
                    try self.check(rc)
                    let data = textPtr.map { Data(bytes: $0, count: max(0, len)) } ?? Data()
                    return makeDiffFromUnified(
                        data: data,
                        truncated: truncated != 0,
                        emptyNotice: "复制自 \(copyFrom)@r\(copyRev32)，内容未修改"
                    )
                }
                if let (data, truncated) = try catContent(url: targetURL, rev: nativeRevision) {
                    if Self.looksBinaryData(data) {
                        return FileDiff(
                            id: change.path,
                            path: change.path,
                            localPath: targetURL,
                            isBinary: true,
                            hunks: [],
                            isTruncated: truncated,
                            statusNotice: "二进制文件，不支持文本差异预览"
                        )
                    }
                    let decoded = Self.decodeText(data, isTruncated: truncated)
                    let text = decoded ?? String(decoding: data, as: UTF8.self)
                    let hunks = Self.synthesizeAdded(text)
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: hunks,
                        isTruncated: truncated,
                        statusNotice: decoded == nil ? "文件内容无法完整解码" : (hunks.isEmpty ? "新增空文件" : nil)
                    )
                }
                return FileDiff(
                    id: change.path,
                    path: change.path,
                    localPath: targetURL,
                    isBinary: false,
                    hunks: [],
                    isTruncated: false,
                    statusNotice: "目录或无文本内容"
                )

            case .deleted:
                let prevRev: Int32 = max(1, nativeRevision - 1)
                if let (data, truncated) = try catContent(url: targetURL, rev: prevRev) {
                    if Self.looksBinaryData(data) {
                        return FileDiff(
                            id: change.path,
                            path: change.path,
                            localPath: targetURL,
                            isBinary: true,
                            hunks: [],
                            isTruncated: truncated,
                            statusNotice: "已删除二进制文件"
                        )
                    }
                    let decoded = Self.decodeText(data, isTruncated: truncated)
                    let text = decoded ?? String(decoding: data, as: UTF8.self)
                    let hunks = Self.synthesizeDeleted(text)
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: hunks,
                        isTruncated: truncated,
                        statusNotice: decoded == nil ? "文件内容无法完整解码" : (hunks.isEmpty ? "已删除空文件" : nil)
                    )
                }
                return FileDiff(
                    id: change.path,
                    path: change.path,
                    localPath: targetURL,
                    isBinary: false,
                    hunks: [],
                    isTruncated: false,
                    statusNotice: "文件已在此修订中删除"
                )

            case .modified:
                var textPtr: UnsafeMutablePointer<CChar>? = nil
                var len: Int = 0
                var truncated: Int32 = 0
                let rc = targetURL.absoluteString.withCString { u in
                    csvn_diff_revision(h, u, nativeRevision, maxBytes, &textPtr, &len, &truncated)
                }
                defer { if let textPtr { csvn_free_string(textPtr) } }
                try self.check(rc)
                let data = textPtr.map { Data(bytes: $0, count: max(0, len)) } ?? Data()
                return makeDiffFromUnified(
                    data: data,
                    truncated: truncated != 0,
                    emptyNotice: "仅属性变更或无可见文本差异"
                )

            case .replaced:
                if let copyFrom = change.copyFromPath, !copyFrom.isEmpty,
                   let copyRev32 = nativeCopyRevision, copyRev32 > 0 {
                    let fromURL = Self.buildRepoURL(root: root, repoRelativePath: copyFrom)
                    var textPtr2: UnsafeMutablePointer<CChar>? = nil
                    var len2: Int = 0
                    var truncated2: Int32 = 0
                    let rc2 = fromURL.absoluteString.withCString { u1 in
                        targetURL.absoluteString.withCString { u2 in
                            csvn_diff_urls(h, u1, copyRev32, u2, nativeRevision, maxBytes, &textPtr2, &len2, &truncated2)
                        }
                    }
                    defer { if let textPtr2 { csvn_free_string(textPtr2) } }
                    try self.check(rc2)
                    let data2 = textPtr2.map { Data(bytes: $0, count: max(0, len2)) } ?? Data()
                    return makeDiffFromUnified(
                        data: data2,
                        truncated: truncated2 != 0,
                        emptyNotice: "复制自 \(copyFrom)@r\(copyRev32)，内容未修改"
                    )
                }

                if revision > 1 {
                    var textPtr2: UnsafeMutablePointer<CChar>? = nil
                    var len2: Int = 0
                    var truncated2: Int32 = 0
                    let rc2 = targetURL.absoluteString.withCString { u in
                        csvn_diff_urls(h, u, nativeRevision - 1, u, nativeRevision, maxBytes, &textPtr2, &len2, &truncated2)
                    }
                    defer { if let textPtr2 { csvn_free_string(textPtr2) } }
                    if rc2 == -7 { try self.check(rc2) }
                    if rc2 == 0 {
                        let data2 = textPtr2.map { Data(bytes: $0, count: max(0, len2)) } ?? Data()
                        return makeDiffFromUnified(
                            data: data2,
                            truncated: truncated2 != 0,
                            emptyNotice: "替换文件与上一修订内容一致"
                        )
                    }
                }

                var textPtr: UnsafeMutablePointer<CChar>? = nil
                var len: Int = 0
                var truncated: Int32 = 0
                let rc = targetURL.absoluteString.withCString { u in
                    csvn_diff_revision(h, u, nativeRevision, maxBytes, &textPtr, &len, &truncated)
                }
                defer { if let textPtr { csvn_free_string(textPtr) } }
                try self.check(rc)
                let data = textPtr.map { Data(bytes: $0, count: max(0, len)) } ?? Data()
                return makeDiffFromUnified(
                    data: data,
                    truncated: truncated != 0,
                    emptyNotice: "替换文件与上一修订内容一致"
                )
            }
        }
    }

    /// 获取指定修订中所有改动文件（或匹配 `path` 过滤条件的文件）的差异列表。
    public func diffRevision(
        _ revision: Int,
        path: String? = nil,
        maxBytes: Int = 2 * 1024 * 1024
    ) async throws -> [FileDiff] {
        try await diffRevision(
            revision,
            path: path,
            maxBytes: maxBytes,
            totalMaxBytes: 32 * 1024 * 1024,
            maxFiles: 512
        )
    }

    public func diffRevision(
        _ revision: Int,
        path: String? = nil,
        maxBytes: Int = 2 * 1024 * 1024,
        totalMaxBytes: Int,
        maxFiles: Int
    ) async throws -> [FileDiff] {
        _ = try Self.nativeInteger(revision, field: "修订号", minimum: 1)
        guard maxBytes >= 0 else { throw VCSError.invalidArgument("差异字节上限不能为负数") }
        guard totalMaxBytes >= 0 else { throw VCSError.invalidArgument("差异总字节上限不能为负数") }
        guard maxFiles >= 0 else { throw VCSError.invalidArgument("差异文件数量上限不能为负数") }
        let logTarget: URL = try await perform {
            let h = try self.requireHandle()
            return try self.resolveRootURLSync(handle: h, explicit: nil)
        }
        let entries = try await self.log(
            workingCopy: logTarget,
            path: nil,
            limit: 1,
            startRevision: revision
        )
        guard let entry = entries.first(where: { $0.revision == revision }) else {
            return []
        }

        let candidateFilters: [String] = {
            guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return [] }
            while p.count > 1 && p.hasSuffix("/") {
                p.removeLast()
            }
            let norm = p.hasPrefix("/") ? p : "/" + p
            var filters = [norm]
            if let base = self.baseURL {
                var basePath = Self.trimTrailingSlash(base).path
                var rootPath = Self.trimTrailingSlash(logTarget).path
                while basePath.count > 1 && basePath.hasSuffix("/") { basePath.removeLast() }
                while rootPath.count > 1 && rootPath.hasSuffix("/") { rootPath.removeLast() }
                if rootPath == "/" && basePath.count > 1 && basePath.hasPrefix("/") {
                    let subFilter = basePath + norm
                    if !filters.contains(subFilter) { filters.append(subFilter) }
                } else if basePath.count > rootPath.count && basePath.hasPrefix(rootPath + "/") {
                    let subPrefix = String(basePath.dropFirst(rootPath.count))
                    let subFilter = subPrefix + norm
                    if !filters.contains(subFilter) { filters.append(subFilter) }
                }
            }
            return filters
        }()

        let effectiveMaxFiles = maxFiles > 0 ? maxFiles : 512
        var remainingTotalBytes = totalMaxBytes > 0 ? totalMaxBytes : (32 * 1024 * 1024)
        var results: [FileDiff] = []

        for change in entry.changes {
            try Task.checkCancellation()
            if !candidateFilters.isEmpty {
                let matches = candidateFilters.contains { filter in
                    change.path == filter || change.path.hasPrefix(filter + "/")
                }
                if !matches { continue }
            }
            if results.count >= effectiveMaxFiles || remainingTotalBytes <= 0 {
                let targetURL = Self.buildRepoURL(root: logTarget, repoRelativePath: change.path)
                results.append(
                    FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: [],
                        isTruncated: true,
                        statusNotice: "该修订包含较多变更，已达到差异预算上限，后续文件未展开"
                    )
                )
                break
            }
            let perFileCap = maxBytes > 0 ? min(maxBytes, remainingTotalBytes) : remainingTotalBytes
            do {
                let d = try await diffFile(
                    revision: revision,
                    change: change,
                    repoRootURL: logTarget,
                    maxBytes: perFileCap
                )
                let approxBytes = d.hunks.reduce(0) { acc, h in
                    acc + h.header.utf8.count + h.lines.reduce(0) { $0 + $1.text.utf8.count + 2 }
                }
                remainingTotalBytes = max(0, remainingTotalBytes - max(approxBytes, d.isTruncated ? perFileCap : 0))
                if change.kind != .directory || !d.propertyChanges.isEmpty { results.append(d) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let targetURL = Self.buildRepoURL(root: logTarget, repoRelativePath: change.path)
                results.append(
                    FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: [],
                        isTruncated: false,
                        statusNotice: "无法获取差异：\(error.localizedDescription)"
                    )
                )
            }
        }
        return results
    }

    /// 把可能包含多个 `Index: <file>` 段的 unified diff 拆分为逐文件的 `FileDiff`。
    public static func parseMultiFileDiff(
        _ raw: String,
        workingCopyPath: String,
        fallbackTarget: String
    ) -> [FileDiff] {
        let lines = normalizeLineEndings(raw).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [(filePath: String, body: String)] = []
        var currentFile: String? = nil
        var currentLines: [String] = []

        func flushSection() {
            guard !currentLines.isEmpty else { return }
            let body = currentLines.joined(separator: "\n")
            let path = currentFile ?? fallbackTarget
            sections.append((filePath: path, body: body))
            currentLines = []
        }

        for line in lines {
            if line.hasPrefix("Index: ") {
                flushSection()
                currentFile = String(line.dropFirst("Index: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentLines.append(line)
        }
        flushSection()

        var results: [FileDiff] = []
        var indexByPath: [String: Int] = [:]
        let cleanWC = workingCopyPath.hasSuffix("/") ? String(workingCopyPath.dropLast()) : workingCopyPath

        for sec in sections {
            let hunks = parseUnifiedDiff(sec.body)
            let isBin = hasBinaryDiffHeader(sec.body)
                || sec.body.utf8.contains(0)
                || isKnownBinaryPath(sec.filePath)
            if hunks.isEmpty && !isBin { continue }

            var rel = sec.filePath
            if rel.hasPrefix(cleanWC + "/") {
                rel = String(rel.dropFirst(cleanWC.count + 1))
            } else if rel == cleanWC {
                rel = "."
            }
            let absPath = sec.filePath.hasPrefix("/")
                ? sec.filePath
                : (cleanWC + "/" + rel)

            if let existingIdx = indexByPath[rel] {
                let prev = results[existingIdx]
                let mergedBin = prev.isBinary || isBin
                results[existingIdx] = FileDiff(
                    id: prev.id,
                    path: prev.path,
                    localPath: prev.localPath,
                    isBinary: mergedBin,
                    hunks: mergedBin ? [] : (prev.hunks + hunks),
                    isTruncated: prev.isTruncated,
                    statusNotice: prev.statusNotice ?? (mergedBin ? "二进制文件，不支持文本差异预览" : nil)
                )
            } else {
                indexByPath[rel] = results.count
                results.append(
                    FileDiff(
                        id: rel,
                        path: rel,
                        localPath: URL(fileURLWithPath: absPath),
                        isBinary: isBin,
                        hunks: isBin ? [] : hunks,
                        statusNotice: isBin ? "二进制文件，不支持文本差异预览" : nil
                    )
                )
            }
        }
        return results
    }

    /// 解析 "-12,34" 形式的头部字段。
    private static func parseRevisionPair(_ s: Substring) -> (Int, Int) {
        let nums = s.split(separator: ",").compactMap { Int($0) }
        return (nums.count > 0 ? nums[0] : 0, nums.count > 1 ? nums[1] : 1)
    }

    /// 解析单文件 unified diff 文本为 hunk 结构。
    public static func parseUnifiedDiff(_ text: String) -> [FileDiff.Hunk] {
        var hunks: [FileDiff.Hunk] = []
        var current: FileDiff.Hunk?
        var oldLine = 0
        var newLine = 0
        var oldConsumed = 0
        var newConsumed = 0

        func flush() {
            if let c = current { hunks.append(c) }
            current = nil
            oldConsumed = 0
            newConsumed = 0
        }

        for line in splitNormalizedLines(text) {
            if line.hasPrefix("Index: ") || line.hasPrefix("===") || line.hasPrefix("Property changes on:") {
                flush()
                continue
            }
            if let c = current, oldConsumed >= c.oldCount && newConsumed >= c.newCount {
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.isEmpty {
                    flush()
                    continue
                }
            }
            if current == nil && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) {
                continue
            }
            if line.hasPrefix("@@") {
                flush()
                // @@ -oldStart,oldCount +newStart,newCount @@
                let fields = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
                let oldNums = fields.first.map { parseRevisionPair(String($0).dropFirst()) } ?? (0, 1)
                let newNums = fields.count > 1 ? parseRevisionPair(String(fields[1]).dropFirst()) : (0, 1)
                let oStart = oldNums.0
                let oCount = oldNums.1
                let nStart = newNums.0
                let nCount = newNums.1
                oldLine = oStart
                newLine = nStart
                oldConsumed = 0
                newConsumed = 0
                current = FileDiff.Hunk(
                    oldStart: oStart, oldCount: oCount,
                    newStart: nStart, newCount: nCount,
                    header: line, lines: []
                )
                continue
            }
            guard var h = current else { continue }
            if line.hasPrefix("+") {
                h.lines.append(.init(kind: .addition, text: String(line.dropFirst()), oldLine: nil, newLine: newLine))
                newLine += 1
                newConsumed += 1
            } else if line.hasPrefix("-") {
                h.lines.append(.init(kind: .deletion, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil))
                oldLine += 1
                oldConsumed += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" —— 忽略
            } else if line.hasPrefix(" ") || line.isEmpty {
                h.lines.append(.init(kind: .context, text: String(line.dropFirst()), oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
                oldConsumed += 1
                newConsumed += 1
            }
            current = h
        }
        flush()
        return hunks
    }

    // MARK: 7. 提交

    public func commit(
        workingCopy: URL,
        paths: [String],
        message: String,
        progress: (@Sendable (VCSTaskProgress) -> Void)?
    ) async throws -> CommitResult {
        try await commitPaths(workingCopy: workingCopy, paths: paths, message: message, exact: false, progress: progress)
    }

    /// 提交已逐项审核的路径。目录项仅提交自身属性，子路径须明确列出。
    public func commitSelection(workingCopy: URL, paths: [String], message: String) async throws -> CommitResult {
        guard !paths.isEmpty else { throw VCSError.invalidArgument("请选择要提交的路径") }
        return try await commitPaths(workingCopy: workingCopy, paths: paths, message: message, exact: true, progress: nil)
    }

    private func commitPaths(
        workingCopy: URL,
        paths: [String],
        message: String,
        exact: Bool,
        progress: (@Sendable (VCSTaskProgress) -> Void)?
    ) async throws -> CommitResult {
        try await performWrite {
            let h = try self.requireHandle()
            let targets = try self.writeTargets(workingCopy, paths, exact: exact, committing: true)
            progress?(VCSTaskProgress(phase: "正在提交改动", completed: 0, total: targets.count, currentPath: targets.first))

            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            var rev: Int32 = 0
            var committed: Int32 = 0
            let count = try Self.nativeInteger(cStrings.count, field: "目标数量", minimum: 1)
            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    message.withCString { m in
                        csvn_commit(h, p, count, m, exact ? 1 : 0, &rev, &committed)
                    }
                }
            }
            try self.check(rc)
            progress?(VCSTaskProgress(phase: "提交完成", completed: Int(committed), total: targets.count, currentPath: nil))
            return CommitResult(revision: Int(rev), committedCount: Int(committed), message: message)
        }
    }

    // MARK: 8. 回滚

    @discardableResult
    public func revert(workingCopy: URL, paths: [String]) async throws -> Int {
        try await revertPaths(workingCopy: workingCopy, paths: paths, exact: false)
    }

    public func revertSelection(workingCopy: URL, paths: [String]) async throws -> Int {
        guard !paths.isEmpty else { throw VCSError.invalidArgument("请选择要放弃的路径") }
        return try await revertPaths(workingCopy: workingCopy, paths: paths, exact: true)
    }

    private func revertPaths(workingCopy: URL, paths: [String], exact: Bool) async throws -> Int {
        try await performWrite {
            let h = try self.requireHandle()
            let targets = try self.writeTargets(workingCopy, paths, exact: exact, committing: false)
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            let count = try Self.nativeInteger(cStrings.count, field: "目标数量", minimum: 1)
            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    csvn_revert(h, p, count, exact ? 1 : 0)
                }
            }
            try self.check(rc)
            return targets.count
        }
    }

    private func writePath(_ path: String, root: String, originalRoot: String) throws -> String {
        try validateCString(path)
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !path.contains("://"), !parts.contains(where: { $0 == ".." || $0.lowercased() == ".svn" }) else {
            throw VCSError.invalidArgument("写入目标必须在指定工作副本内")
        }
        let normalized = parts.joined(separator: "/")
        if !path.hasPrefix("/") { return normalized.isEmpty ? root : root + "/" + normalized }
        let absolute = "/" + normalized
        for anchor in [root, originalRoot] {
            if absolute == anchor { return root }
            if absolute.hasPrefix(anchor + "/") { return root + absolute.dropFirst(anchor.count) }
        }
        throw VCSError.invalidArgument("写入目标必须在指定工作副本内")
    }

    private func validateWriteTargets(_ targets: [String], root: String,
                                      recursiveRevert: Bool = false, adding: Bool = false) throws {
        let count = try Self.nativeInteger(targets.count, field: "目标数量", minimum: 1)
        var paths: [UnsafePointer<CChar>?] = targets.map { strdup($0).map { UnsafePointer($0) } }
        defer { paths.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard !paths.contains(where: { $0 == nil }) else { throw VCSError.underlying("无法分配路径") }
        let h = try requireHandle()
        try check(csvn_validate_write_targets(h, root, &paths, count, recursiveRevert ? 1 : 0, adding ? 1 : 0))
    }

    private func writeTargets(_ wc: URL, _ paths: [String], exact: Bool, committing: Bool) throws -> [String] {
        let root = try writeRoot(wc)
        func absolute(_ relative: String) -> String { relative == "." ? root : root + "/" + relative }
        var targets = paths.isEmpty ? [root] : Set(try paths.map {
            try writePath($0, root: root, originalRoot: wc.standardizedFileURL.path)
        })
        let recursiveRevert = !committing && !exact
        try validateWriteTargets(targets.sorted(), root: root, recursiveRevert: recursiveRevert)
        let statuses = try readStatus(root)
        if exact {
            let available = Set(statuses.map { absolute($0.path) })
            guard targets.isSubset(of: available) else {
                throw VCSError.invalidArgument("所选路径状态已改变，请刷新工作副本")
            }
        }
        func includes(_ path: String) -> Bool {
            targets.contains(path) || (!exact && targets.contains { path.hasPrefix($0 + "/") })
        }
        var changed = true
        while changed {
            changed = false
            for item in statuses where includes(absolute(item.path)) {
                for partner in [item.movedFrom, item.movedTo].compactMap({ $0 }) where !includes(absolute(partner)) {
                    let target = try writePath(partner, root: root, originalRoot: root)
                    try validateWriteTargets([target], root: root, recursiveRevert: recursiveRevert)
                    targets.insert(target)
                    changed = true
                }
            }
        }
        if committing {
            let conflicts = statuses.filter { $0.kind == .conflicted && includes(absolute($0.path)) }
            if !conflicts.isEmpty { throw VCSError.conflictsPresent(conflicts.map(\.path)) }
            if statuses.contains(where: \.mergeInfoChanged),
               statuses.contains(where: { $0.kind.isPendingChange && !includes(absolute($0.path)) }) {
                throw VCSError.invalidArgument("检测到合并记录变更，请审核并一并提交所有待提交的版本化路径")
            }
        }
        if !committing, statuses.contains(where: {
            $0.movedFrom != nil && includes(absolute($0.path)) && ($0.movedDestinationModified || $0.isDirectory)
        }) {
            throw VCSError.invalidArgument("移动目标含本地改动或是目录，请先备份后再处理，防止丢失数据")
        }
        try checkActiveCancellation()
        return targets.sorted()
    }

    // MARK: - P0 工作副本文件操作

    private func writeRoot(_ url: URL) throws -> String {
        guard url.isFileURL else { throw VCSError.invalidArgument("需要本地 SVN 工作副本") }
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path
        try validateCString(root)
        return root
    }

    private func validateCString(_ value: String) throws {
        guard !value.utf8.contains(0) else { throw VCSError.invalidArgument("路径包含空字符") }
    }

    public func delete(workingCopy: URL, paths: [String]) async throws -> [String] {
        let root = try writeRoot(workingCopy)
        let paths = Array(Set(paths)).sorted()
        guard !paths.isEmpty, let count = Int32(exactly: paths.count) else {
            throw VCSError.invalidArgument("请指定要删除的文件")
        }
        for path in paths { try validateCString(path) }
        return try await performWrite {
            let h = try self.requireHandle()
            var strings: [UnsafePointer<CChar>?] = paths.map { strdup($0).map { UnsafePointer($0) } }
            defer { strings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            guard !strings.contains(where: { $0 == nil }) else {
                throw VCSError.underlying("无法分配路径")
            }
            try self.check(csvn_delete_files(h, root, &strings, count))
            return paths
        }
    }

    public func move(workingCopy: URL, source: String, destination: String) async throws -> [String] {
        try await transfer(workingCopy, source, destination, copying: false)
    }

    public func copy(workingCopy: URL, source: String, destination: String) async throws -> [String] {
        try await transfer(workingCopy, source, destination, copying: true)
    }

    private func transfer(_ wc: URL, _ source: String, _ destination: String, copying: Bool) async throws -> [String] {
        let root = try writeRoot(wc)
        try validateCString(source)
        try validateCString(destination)
        return try await performWrite {
            let h = try self.requireHandle()
            let rc = copying ? csvn_copy_file(h, root, source, destination)
                             : csvn_move_file(h, root, source, destination)
            try self.check(rc)
            return copying ? [destination] : [source, destination]
        }
    }

    public func resolve(workingCopy: URL, path: String, strategy: ConflictResolution) async throws {
        let root = try writeRoot(workingCopy)
        try validateCString(path)
        guard let option = ConflictResolution.allCases.firstIndex(of: strategy) else {
            throw VCSError.invalidArgument("未知冲突策略")
        }
        try await performWrite {
            let h = try self.requireHandle()
            try self.check(csvn_resolve_text(h, root, path, Int32(option)))
        }
    }

    public func merge(workingCopy: URL, request: MergeRequest, dryRun: Bool) async throws -> MergeResult {
        let root = try writeRoot(workingCopy)
        let source = request.source
        guard source.user == nil, source.password == nil, source.query == nil, source.fragment == nil else {
            throw VCSError.invalidArgument("合并源需为无附加凭据或参数的仓库 URL")
        }
        return try await performWrite {
            guard let targetURL = Self.workingCopyURL(at: URL(fileURLWithPath: root)),
                  (source.isFileURL && targetURL.isFileURL) ||
                    (SVNOrigin(source) != nil && SVNOrigin(source) == SVNOrigin(targetURL)) else {
                throw VCSError.invalidArgument("合并源必须与目标使用同一 SVN 端点")
            }
            let h = try self.requireHandle()
            var raw = csvn_merge_result()
            defer { csvn_free_merge_result(&raw) }
            let rc = csvn_merge_range(h, root, source.absoluteString, request.from,
                                      request.to, request.peg, dryRun ? 1 : 0, &raw)
            do {
                try self.check(rc)
            } catch {
                if !dryRun && raw.started != 0 { throw VCSError.mergeInterrupted(error.localizedDescription) }
                throw error
            }
            func paths(_ items: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ count: Int32) -> [String] {
                guard let items else { return [] }
                return (0..<Int(count)).compactMap { items[$0].map { String(cString: $0) } }.sorted()
            }
            let changed = paths(raw.changed, raw.changed_count)
            let conflicts = paths(raw.conflicts, raw.conflict_count)
            let skipped = paths(raw.skipped, raw.skipped_count)
            if !dryRun, let actual = try? self.readStatus(root) {
                return MergeResult(request: request, dryRun: false,
                                   changedPaths: actual.filter { $0.kind.isPendingChange }.map(\.path).sorted(),
                                   conflictedPaths: actual.filter { $0.kind == .conflicted }.map(\.path).sorted(),
                                   skippedPaths: skipped)
            }
            return MergeResult(request: request, dryRun: dryRun, changedPaths: changed,
                               conflictedPaths: conflicts, skippedPaths: skipped, refreshRequired: !dryRun)
        }
    }

    // MARK: - 节点属性与目录

    private static func nativeInteger(_ value: Int, field: String, minimum: Int = 0) throws -> Int32 {
        guard value >= minimum, let result = Int32(exactly: value) else {
            throw VCSError.invalidArgument("\(field)须在 \(minimum)...\(Int32.max) 范围内")
        }
        return result
    }

    private func propertyRevision(_ revision: Int?) throws -> Int32 {
        guard let revision else { return -1 }
        return try Self.nativeInteger(revision, field: "修订号")
    }

    private func readProperties(at target: PropertyTarget, name: String?, revision: Int?,
                                peg: Int?, inherited: Bool) async throws -> [NodeProperty] {
        let root: String?
        let path: String
        switch target {
        case .workingCopy(let wc, let relative):
            root = try writeRoot(wc)
            path = relative
        case .repository(let url):
            guard (url.isFileURL || SVNOrigin(url) != nil), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else {
                throw VCSError.invalidArgument("需要不含凭据、查询参数或片段的仓库 URL")
            }
            root = nil
            path = url.absoluteString
        }
        try validateCString(path)
        if let name { try validateCString(name) }
        let revision = try propertyRevision(revision)
        let peg = try propertyRevision(peg)
        return try await perform {
            var rows: UnsafeMutablePointer<csvn_property>?
            var count: Int32 = 0
            defer { csvn_free_properties(rows, count) }
            let h = try self.requireHandle()
            try self.check(csvn_properties(h, root, path, name, revision, peg,
                                           inherited ? 1 : 0, &rows, &count))
            guard let rows else { return [] }
            return (0..<Int(count)).map { index in
                let row = rows[index]
                let value = row.data.map { Data(bytes: $0, count: row.length) } ?? Data()
                return NodeProperty(target: target, source: row.source.map { String(cString: $0) },
                                    name: String(cString: row.name), value: value)
            }.sorted { ($0.name, $0.source ?? "") < ($1.name, $1.source ?? "") }
        }
    }

    public func properties(at target: PropertyTarget, revision: Int? = nil, peg: Int? = nil,
                           inherited: Bool = false) async throws -> [NodeProperty] {
        try await readProperties(at: target, name: nil, revision: revision, peg: peg, inherited: inherited)
    }

    public func property(_ name: String, at target: PropertyTarget, revision: Int? = nil,
                         peg: Int? = nil) async throws -> Data? {
        try await readProperties(at: target, name: name, revision: revision, peg: peg,
                                 inherited: false).first?.value
    }

    public func setProperty(_ name: String, value: Data?, workingCopy: URL, path: String) async throws {
        let root = try writeRoot(workingCopy)
        try validateCString(path)
        try validateCString(name)
        guard NodeProperty.allowsEditing(name) else { throw VCSError.invalidArgument("此属性为只读") }
        if name.hasPrefix("svn:"), let value, value.contains(0) || String(data: value, encoding: .utf8) == nil {
            throw VCSError.invalidArgument("此 SVN 属性需要 UTF-8 文本")
        }
        try await performWrite {
            let h = try self.requireHandle()
            try (value ?? Data()).withUnsafeBytes { buffer in
                try self.check(csvn_set_property(h, root, path, name, buffer.baseAddress,
                                                 buffer.count, value == nil ? 1 : 0))
            }
        }
    }

    private func readNativeStrings(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
                                            UnsafeMutablePointer<Int32>) -> Int32) throws -> [String] {
        var values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        defer { csvn_free_string_array(values, count) }
        try check(body(&values, &count))
        guard let values else { return [] }
        return (0..<Int(count)).compactMap { values[$0].map { String(cString: $0) } }
    }

    public func ignoreRules(workingCopy: URL, directory: String) async throws -> IgnoreRules {
        let root = try writeRoot(workingCopy)
        let url = URL(fileURLWithPath: root).appendingPathComponent(directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw VCSError.invalidArgument("请选择工作副本目录") }
        let properties = try await properties(at: .workingCopy(root: workingCopy, path: directory), inherited: true)
        let defaults = try await perform {
            let h = try self.requireHandle()
            return try self.readNativeStrings { csvn_default_ignores(h, $0, $1) }
        }
        return IgnoreRules(defaults: defaults,
                           directoryRules: properties.first { $0.name == "svn:ignore" && $0.source == nil },
                           globalRules: properties.filter { $0.name == "svn:global-ignores" })
    }

    public func previewDirectory(workingCopy: URL, path: String, parents: Bool) async throws -> [String] {
        try await directoryOperation(workingCopy: workingCopy, path: path, parents: parents,
                                     preview: true, expectedCount: nil)
    }

    public func makeDirectory(workingCopy: URL, path: String, parents: Bool,
                              expectedCount: Int? = nil) async throws -> [String] {
        try await directoryOperation(workingCopy: workingCopy, path: path, parents: parents,
                                     preview: false, expectedCount: expectedCount)
    }

    private func directoryOperation(workingCopy: URL, path: String, parents: Bool, preview: Bool,
                                    expectedCount: Int?) async throws -> [String] {
        let root = try writeRoot(workingCopy)
        try validateCString(path)
        let expected = try propertyRevision(expectedCount)
        return try await performWrite {
            let h = try self.requireHandle()
            return try self.readNativeStrings {
                csvn_mkdir_working(h, root, path, parents ? 1 : 0, preview ? 1 : 0, expected, $0, $1)
            }
        }
    }

    // MARK: 9. 日志

    public func log(
        workingCopy: URL,
        path: String?,
        limit: Int,
        startRevision: Int?
    ) async throws -> [LogEntry] {
        let nativeLimit = try Self.nativeInteger(limit, field: "日志数量")
        let nativeStart = try Self.nativeInteger(startRevision ?? 0, field: "起始修订号")
        return try await perform {
            let h = try self.requireHandle()
            var items: UnsafeMutablePointer<csvn_log_entry>? = nil
            var count: Int32 = 0

            // 目标路径：可以是工作副本里的相对路径，也可以直接给仓库 URL
            // （svn_client_log4 的 target 既接受工作副本路径，也接受 URL）
            //
            // 工作副本子目录没有自己的 .svn；让 libsvn 查询所属工作副本。
            let isWorkingCopyDir = workingCopy.isFileURL &&
                Self.workingCopyURL(at: workingCopy) != nil
            let target: String
            if !isWorkingCopyDir, workingCopy.scheme != nil {
                guard (workingCopy.isFileURL && workingCopy.user == nil && workingCopy.password == nil) ||
                      SVNOrigin(workingCopy) != nil else {
                    throw VCSError.invalidArgument("请通过独立参数传递凭据")
                }
                var u = workingCopy
                if let path, !path.isEmpty {
                    for comp in path.split(separator: "/") where !comp.isEmpty {
                        u = u.appendingPathComponent(String(comp))
                    }
                }
                target = u.absoluteString
            } else {
                target = path.map { self.localPath(workingCopy, $0) } ?? workingCopy.path
            }
            let rc: Int32 = target.withCString { p in
                csvn_log(h, p, nativeLimit, nativeStart, &items, &count)
            }
            try self.check(rc)
            defer { csvn_free_log(items, count) }
            guard let items else { return [] }

            var result: [LogEntry] = []
            result.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                var e = items.advanced(by: i).pointee
                let author = String(cString: csvn_log_author_p(&e))
                let msg = e.message.map { String(cString: $0) } ?? ""
                var changed: [String] = []
                var structuredChanges: [ChangedPath] = []
                let n = Int(e.changed_count)
                changed.reserveCapacity(n)
                structuredChanges.reserveCapacity(n)

                if let paths = e.changed_paths {
                    for j in 0..<n {
                        guard let p = paths.advanced(by: j).pointee else { continue }
                        let rawStr = String(cString: p)
                        changed.append(rawStr)

                        var nodeKind: ChangedPath.NodeKind = .unknown
                        if let kinds = e.changed_kinds {
                            let k = kinds.advanced(by: j).pointee
                            if k == 0x66 { nodeKind = .file }       // 'f'
                            else if k == 0x64 { nodeKind = .directory } // 'd'
                        }

                        var copyFromPath: String? = nil
                        var copyFromRev: Int? = nil
                        if let cfArr = e.copyfrom_paths, let cfPtr = cfArr.advanced(by: j).pointee {
                            let cfStr = String(cString: cfPtr)
                            if let atIdx = cfStr.lastIndex(of: "@"),
                               let rev = Int(cfStr[cfStr.index(after: atIdx)...]) {
                                copyFromPath = String(cfStr[..<atIdx])
                                copyFromRev = rev
                            } else if !cfStr.isEmpty {
                                copyFromPath = cfStr
                            }
                        }

                        structuredChanges.append(
                            ChangedPath.parse(
                                rawStr,
                                kind: nodeKind,
                                copyFromPath: copyFromPath,
                                copyFromRevision: copyFromRev
                            )
                        )
                    }
                }
                result.append(
                    LogEntry(
                        id: "r\(e.revision)",
                        revision: Int(e.revision),
                        author: author,
                        date: Date(timeIntervalSince1970: Double(e.timestamp) / 1_000_000),
                        message: msg,
                        changedPaths: changed,
                        changes: structuredChanges
                    )
                )
            }
            return result
        }
    }

    // MARK: 10. 新增 (svn add) 与文件内容读取 (svn cat)

    /// 将未版本控制的文件或目录纳入版本控制（`svn add`）。
    @discardableResult
    public func add(workingCopy: URL, paths: [String]) async throws -> Int {
        try await performWrite {
            let h = try self.requireHandle()
            let root = try self.writeRoot(workingCopy)
            let targets = paths.isEmpty ? [root] : try paths.map {
                try self.writePath($0, root: root, originalRoot: workingCopy.standardizedFileURL.path)
            }
            try self.validateWriteTargets(targets, root: root, adding: true)
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            let count = try Self.nativeInteger(cStrings.count, field: "目标数量", minimum: 1)
            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    csvn_add(h, p, count)
                }
            }
            try self.check(rc)
            return targets.count
        }
    }

    /// 读取远端仓库中指定路径文件的内容（`svn cat`）。
    public func cat(path: String, revision: Int? = nil) async throws -> Data {
        try await cat(path: path, revision: revision, maxBytes: 0).data
    }

    /// 读取远端仓库中指定路径文件的内容（支持 `maxBytes` C 层流式截断保护）。
    public func cat(path: String, revision: Int? = nil, maxBytes: Int) async throws -> (data: Data, isTruncated: Bool) {
        let nativeRevision = try Self.nativeInteger(revision ?? 0, field: "修订号")
        guard maxBytes >= 0 else { throw VCSError.invalidArgument("读取字节上限不能为负数") }
        let target = try url(for: path)
        return try await perform {
            let h = try self.requireHandle()
            var buf: UnsafeMutablePointer<CChar>? = nil
            var len: Int = 0
            var truncated: Int32 = 0
            let rc = target.absoluteString.withCString { u in
                csvn_cat_capped(h, u, nativeRevision, maxBytes, &buf, &len, &truncated)
            }
            try self.check(rc)
            defer { if let buf { csvn_free_string(buf) } }
            guard let buf, len > 0 else { return (Data(), truncated != 0) }
            return (Data(bytes: buf, count: len), truncated != 0)
        }
    }
}

/// 差异解析辅助工具集（纯函数）
public enum DiffParser {
    public static func parseUnified(_ text: String) -> [FileDiff.Hunk] {
        SVNClient.parseUnifiedDiff(text)
    }

    public static func synthesizeAdded(_ content: String) -> [FileDiff.Hunk] {
        SVNClient.synthesizeAdded(content)
    }

    public static func synthesizeDeleted(_ content: String) -> [FileDiff.Hunk] {
        SVNClient.synthesizeDeleted(content)
    }

    public static func decode(_ data: Data) -> String? {
        SVNClient.decodeText(data)
    }

    public static func looksBinary(_ data: Data, path: String) -> Bool {
        SVNClient.isKnownBinaryPath(path) || SVNClient.looksBinaryData(data)
    }
}
