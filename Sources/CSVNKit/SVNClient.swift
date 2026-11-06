import CVCSKit
import CSVNShim
import Foundation

/// SVN 后端：把 libsvn 的同步 C 接口包装成 `RepositoryClient` 协议。
///
/// 线程模型：所有 libsvn 调用都排到一条私有串行队列上执行，
/// 因此不会阻塞协作式线程池，也天然满足 `RepositoryClient` 的并发调用要求。
public final class SVNClient: RepositoryClient, @unchecked Sendable {

    // MARK: 存储

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "vcs.svn.backend", qos: .userInitiated)
    private let stateLock = NSLock()
    private let username: String?
    private let password: String?
    private let configDir: String?
    private let trustBundlePath: String?
    private let useSavedCredentials: Bool
    private var credentialURL: URL?
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
        self.username = username
        self.password = password
        self.configDir = configDir
        self.trustBundlePath = trustBundlePath
        self.useSavedCredentials = useSavedCredentials
        credentialURL = baseURL
        self.baseURL = baseURL
        handle = try createHandle(url: baseURL, credentials: nil).handle
    }

    deinit {
        if let h = handle { csvn_context_destroy(h) }
    }

    private func createHandle(url: URL?, credentials: Credentials?) throws
        -> (handle: OpaquePointer, user: String?, password: String?) {
        if let url, url.password != nil || (url.user != nil && url.scheme?.lowercased() != "svn+ssh") {
            throw VCSError.invalidArgument("请通过独立参数传递凭据")
        }
        var user = username
        var secret = password
        var realm: String?
        if let url, let credentialURL, Self.trimTrailingSlash(credentialURL) != Self.trimTrailingSlash(url) {
            user = nil
            secret = nil
        }
        switch credentials?.kind {
        case .usernamePassword(let suppliedUser, let suppliedPassword):
            user = suppliedUser
            secret = suppliedPassword
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
        defer { for value in cStrings { free(value) } }
        guard let h = csvn_context_create(cStrings[0], cStrings[1], cStrings[2], cStrings[3],
                                          cStrings[4], cStrings[5], cStrings[6], cStrings[7],
                                          &errbuf, Int32(errbuf.count)) else {
            throw VCSError.underlying("无法初始化 SVN 上下文：\(String(cString: errbuf))")
        }
        return (h, user, secret)
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

    /// 在私有队列上执行一段阻塞的 libsvn 调用。
    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
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
        return str.isEmpty ? nil : URL(string: str)
    }

    // MARK: 1. 连接

    public func connect(to url: URL, credentials: Credentials?) async throws -> RepositoryInfo {
        try await perform {
            self.rememberedConnection = nil
            let candidate = try self.createHandle(url: url, credentials: credentials)
            let h = candidate.handle
            let previous = self.handle
            self.handle = h
            var connected = false
            defer {
                if connected {
                    if let previous { csvn_context_destroy(previous) }
                } else {
                    self.handle = previous
                    csvn_context_destroy(h)
                }
            }
            var uuid = [CChar](repeating: 0, count: 256)
            var rev: Int32 = 0
            let rc = url.absoluteString.withCString { u in
                csvn_connect(h, u, &uuid, Int32(uuid.count), &rev)
            }
            try self.check(rc)
            self.baseURL = Self.trimTrailingSlash(url)

            var rootBuf = [CChar](repeating: 0, count: 2048)
            let rootRC = url.absoluteString.withCString { u in
                csvn_get_repos_root(h, u, &rootBuf, Int32(rootBuf.count))
            }
            if rootRC == 0 {
                let rootStr = String(cString: rootBuf)
                if !rootStr.isEmpty, let resolved = URL(string: rootStr) {
                    self.rootURL = Self.trimTrailingSlash(resolved)
                } else {
                    self.rootURL = nil
                }
            } else {
                self.rootURL = nil
            }

            if KeychainStore.service(for: url) != nil,
               let username = candidate.user, let password = candidate.password,
               let value = csvn_auth_realm(h), value.pointee != 0 {
                self.rememberedConnection = (url, username, password, String(cString: value))
            }
            if self.credentialURL == nil {
                self.credentialURL = url
            }
            connected = true
            return RepositoryInfo(
                url: url,
                uuid: String(cString: uuid).isEmpty ? nil : String(cString: uuid),
                revision: Int(rev),
                youngestRevision: Int(rev),
                rootURL: self.rootURL ?? Self.trimTrailingSlash(url)
            )
        }
    }

    public func disconnect() async {
        try? await perform {
            if let handle = self.handle {
                csvn_context_destroy(handle)
                self.handle = nil
            }
            self.rememberedConnection = nil
            self.baseURL = nil
            self.rootURL = nil
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
        let target = try url(for: path)
        return try await perform {
            let h = try self.requireHandle()
            var rev: Int32 = 0
            let dest = destination.path
            let rc = target.absoluteString.withCString { u in
                dest.withCString { d in
                    csvn_checkout(h, u, d, Int32(revision ?? 0), &rev)
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
        try await perform {
            let h = try self.requireHandle()
            let wc = workingCopy.path
            var rev: Int32 = 0
            var updated: Int32 = 0
            var added: Int32 = 0
            var deleted: Int32 = 0
            var conflicts: UnsafeMutablePointer<CChar>? = nil
            var conflictCount: Int32 = 0

            let rc = wc.withCString { p in
                csvn_update(h, p, Int32(revision ?? 0), &rev, &updated, &added, &deleted,
                            &conflicts, &conflictCount)
            }
            try self.check(rc)
            defer { if let conflicts { csvn_free_string(conflicts) } }

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
        try await perform {
            let h = try self.requireHandle()
            let wcPath = workingCopy.standardizedFileURL.path
            var items: UnsafeMutablePointer<csvn_status_item>? = nil
            var count: Int32 = 0

            let rc = wcPath.withCString { p in
                csvn_status(h, p, &items, &count)
            }
            try self.check(rc)
            defer { csvn_free_status(items, count) }
            guard let items else { return [] }

            var result: [WorkingCopyStatus] = []
            result.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                var s = items.advanced(by: i).pointee
                let path = String(cString: csvn_status_path_p(&s))
                let name = String(cString: csvn_status_name_p(&s))
                let lockOwner = String(cString: csvn_status_lock_p(&s))
                let kind = Self.mapStatusKind(s.kind)

                // 相对工作副本根的路径
                var rel = path
                if path == wcPath {
                    rel = "."
                } else if path.hasPrefix(wcPath + "/") {
                    rel = String(path.dropFirst(wcPath.count + 1))
                } else if path.hasPrefix(workingCopy.path) {
                    rel = String(path.dropFirst(workingCopy.path.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    if rel.isEmpty { rel = "." }
                }

                // 若是工作副本根目录自身且无改动，则不冗余展示 "."
                if rel == "." && kind == .normal {
                    continue
                }

                result.append(
                    WorkingCopyStatus(
                        id: rel,
                        path: rel,
                        name: rel == "." ? "." : name,
                        kind: kind,
                        baseRevision: Int(s.base_revision),
                        workingRevision: s.working_revision >= 0 ? Int(s.working_revision) : nil,
                        isDirectory: s.is_directory != 0,
                        lockOwner: lockOwner.isEmpty ? nil : lockOwner
                    )
                )
            }
            return result
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

    /// 支持 UTF-8 与 GB18030 解码（兼容被截断的多字节尾部与混合编码的 diff 头/正文）。
    public static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if looksBinaryData(data) { return nil }

        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        if data.count > 4 {
            for trim in 1...3 {
                if let s = String(data: data.dropLast(trim), encoding: .utf8) {
                    return s
                }
            }
        }

        let gbEnc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let gbEncoding = String.Encoding(rawValue: gbEnc)
        if let s = String(data: data, encoding: gbEncoding) {
            return s
        }
        if data.count > 4 {
            for trim in 1...3 {
                if let s = String(data: data.dropLast(trim), encoding: gbEncoding) {
                    return s
                }
            }
        }

        // 逐行回退解码（应对 UTF-8 头部 + GB18030 正文混合的 diff 输出）
        let lineSlices = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var decodedLines: [String] = []
        decodedLines.reserveCapacity(lineSlices.count)
        for (idx, slice) in lineSlices.enumerated() {
            let lineData = Data(slice)
            if let u = String(data: lineData, encoding: .utf8) {
                decodedLines.append(u)
            } else if let g = String(data: lineData, encoding: gbEncoding) {
                decodedLines.append(g)
            } else if idx == lineSlices.count - 1, lineData.count > 4 {
                var recovered: String? = nil
                for trim in 1...3 {
                    if let u = String(data: lineData.dropLast(trim), encoding: .utf8) {
                        recovered = u
                        break
                    }
                    if let g = String(data: lineData.dropLast(trim), encoding: gbEncoding) {
                        recovered = g
                        break
                    }
                }
                guard let recovered else { return nil }
                decodedLines.append(recovered)
            } else {
                return nil
            }
        }
        return decodedLines.joined(separator: "\n")
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
        if rawData.isEmpty { return "" }
        if let whole = decodeText(rawData) {
            return whole
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

        let decodedSections = sectionsData.map { secData in
            decodeText(secData) ?? String(decoding: secData, as: UTF8.self)
        }
        return decodedSections.joined(separator: "\n")
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

    public func diff(workingCopy: URL, paths: [String]) async throws -> [FileDiff] {
        try await perform {
            let h = try self.requireHandle()
            let wcPath = workingCopy.standardizedFileURL.path
            let targets = paths.isEmpty ? [wcPath] : paths.map { self.localPath(workingCopy, $0) }

            var out: [FileDiff] = []
            for t in targets {
                var text: UnsafeMutablePointer<CChar>? = nil
                var len: Int = 0
                let rc = t.withCString { p in
                    csvn_diff(h, p, &text, &len)
                }
                try self.check(rc)
                defer { if let text { csvn_free_string(text) } }
                guard let text, len > 0 else { continue }
                let data = Data(bytes: text, count: len)
                let raw = Self.decodeMultiFileDiffData(data)
                if raw.isEmpty { continue }

                let parsed = Self.parseMultiFileDiff(raw, workingCopyPath: wcPath, fallbackTarget: t)
                out.append(contentsOf: parsed)
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

            func catContent(url: URL, rev: Int) -> (data: Data, truncated: Bool)? {
                var buf: UnsafeMutablePointer<CChar>? = nil
                var len: Int = 0
                let rc = url.absoluteString.withCString { u in
                    csvn_cat(h, u, Int32(rev), &buf, &len)
                }
                defer { if let buf { csvn_free_string(buf) } }
                guard rc == 0, let buf else { return nil }
                if maxBytes > 0 && len > maxBytes {
                    return (Data(bytes: buf, count: maxBytes), true)
                }
                return (Data(bytes: buf, count: max(0, len)), false)
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
                let text = Self.decodeText(data) ?? String(decoding: data, as: UTF8.self)
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
                    statusNotice: hunks.isEmpty ? emptyNotice : nil
                )
            }

            switch change.action {
            case .added:
                if let copyFrom = change.copyFromPath, !copyFrom.isEmpty,
                   let copyRev = change.copyFromRevision, copyRev > 0 {
                    let fromURL = Self.buildRepoURL(root: root, repoRelativePath: copyFrom)
                    var textPtr: UnsafeMutablePointer<CChar>? = nil
                    var len: Int = 0
                    var truncated: Int32 = 0
                    let rc = fromURL.absoluteString.withCString { u1 in
                        targetURL.absoluteString.withCString { u2 in
                            csvn_diff_urls(h, u1, Int32(copyRev), u2, Int32(revision), maxBytes, &textPtr, &len, &truncated)
                        }
                    }
                    defer { if let textPtr { csvn_free_string(textPtr) } }
                    try self.check(rc)
                    let data = textPtr.map { Data(bytes: $0, count: max(0, len)) } ?? Data()
                    return makeDiffFromUnified(
                        data: data,
                        truncated: truncated != 0,
                        emptyNotice: "复制自 \(copyFrom)@r\(copyRev)，内容未修改"
                    )
                }
                if let (data, truncated) = catContent(url: targetURL, rev: revision) {
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
                    let text = Self.decodeText(data) ?? String(decoding: data, as: UTF8.self)
                    let hunks = Self.synthesizeAdded(text)
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: hunks,
                        isTruncated: truncated,
                        statusNotice: hunks.isEmpty ? "新增空文件" : nil
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
                let prevRev = max(1, revision - 1)
                if let (data, truncated) = catContent(url: targetURL, rev: prevRev) {
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
                    let text = Self.decodeText(data) ?? String(decoding: data, as: UTF8.self)
                    let hunks = Self.synthesizeDeleted(text)
                    return FileDiff(
                        id: change.path,
                        path: change.path,
                        localPath: targetURL,
                        isBinary: false,
                        hunks: hunks,
                        isTruncated: truncated,
                        statusNotice: hunks.isEmpty ? "已删除空文件" : nil
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
                    csvn_diff_revision(h, u, Int32(revision), maxBytes, &textPtr, &len, &truncated)
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
                   let copyRev = change.copyFromRevision, copyRev > 0 {
                    let fromURL = Self.buildRepoURL(root: root, repoRelativePath: copyFrom)
                    var textPtr2: UnsafeMutablePointer<CChar>? = nil
                    var len2: Int = 0
                    var truncated2: Int32 = 0
                    let rc2 = fromURL.absoluteString.withCString { u1 in
                        targetURL.absoluteString.withCString { u2 in
                            csvn_diff_urls(h, u1, Int32(copyRev), u2, Int32(revision), maxBytes, &textPtr2, &len2, &truncated2)
                        }
                    }
                    defer { if let textPtr2 { csvn_free_string(textPtr2) } }
                    try self.check(rc2)
                    let data2 = textPtr2.map { Data(bytes: $0, count: max(0, len2)) } ?? Data()
                    return makeDiffFromUnified(
                        data: data2,
                        truncated: truncated2 != 0,
                        emptyNotice: "复制自 \(copyFrom)@r\(copyRev)，内容未修改"
                    )
                }

                if revision > 1 {
                    var textPtr2: UnsafeMutablePointer<CChar>? = nil
                    var len2: Int = 0
                    var truncated2: Int32 = 0
                    let rc2 = targetURL.absoluteString.withCString { u in
                        csvn_diff_urls(h, u, Int32(revision - 1), u, Int32(revision), maxBytes, &textPtr2, &len2, &truncated2)
                    }
                    defer { if let textPtr2 { csvn_free_string(textPtr2) } }
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
                    csvn_diff_revision(h, u, Int32(revision), maxBytes, &textPtr, &len, &truncated)
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

        let normalizedFilter: String? = {
            guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
            while p.count > 1 && p.hasSuffix("/") {
                p.removeLast()
            }
            return p.hasPrefix("/") ? p : "/" + p
        }()

        var results: [FileDiff] = []
        for change in entry.changes {
            if change.kind == .directory { continue }
            if let filter = normalizedFilter {
                let matches = change.path == filter
                    || change.path.hasPrefix(filter + "/")
                    || change.path.hasSuffix(filter)
                if !matches { continue }
            }
            do {
                let d = try await diffFile(
                    revision: revision,
                    change: change,
                    repoRootURL: logTarget,
                    maxBytes: maxBytes
                )
                results.append(d)
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
        try await perform {
            let h = try self.requireHandle()
            let targets = paths.isEmpty ? [workingCopy.path] : paths.map { self.localPath(workingCopy, $0) }

            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            var rev: Int32 = 0
            var committed: Int32 = 0
            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    message.withCString { m in
                        csvn_commit(h, p, Int32(buf.count), m, &rev, &committed)
                    }
                }
            }
            try self.check(rc)
            return CommitResult(revision: Int(rev), committedCount: Int(committed), message: message)
        }
    }

    // MARK: 8. 回滚

    @discardableResult
    public func revert(workingCopy: URL, paths: [String]) async throws -> Int {
        try await perform {
            let h = try self.requireHandle()
            let targets = paths.isEmpty ? [workingCopy.path] : paths.map { self.localPath(workingCopy, $0) }
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    csvn_revert(h, p, Int32(buf.count))
                }
            }
            try self.check(rc)
            return targets.count
        }
    }

    // MARK: 9. 日志

    public func log(
        workingCopy: URL,
        path: String?,
        limit: Int,
        startRevision: Int?
    ) async throws -> [LogEntry] {
        try await perform {
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
                csvn_log(h, p, Int32(limit), Int32(startRevision ?? 0), &items, &count)
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
        try await perform {
            let h = try self.requireHandle()
            let targets = paths.isEmpty ? [workingCopy.path] : paths.map { self.localPath(workingCopy, $0) }
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for s in cStrings { free(s) } }
            cStrings = targets.map { strdup($0) }

            let rc = cStrings.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                    csvn_add(h, p, Int32(buf.count))
                }
            }
            try self.check(rc)
            return targets.count
        }
    }

    /// 读取远端仓库中指定路径文件的内容（`svn cat`）。
    public func cat(path: String, revision: Int? = nil) async throws -> Data {
        let target = try url(for: path)
        return try await perform {
            let h = try self.requireHandle()
            var buf: UnsafeMutablePointer<CChar>? = nil
            var len: Int = 0
            let rc = target.absoluteString.withCString { u in
                csvn_cat(h, u, Int32(revision ?? 0), &buf, &len)
            }
            try self.check(rc)
            defer { if let buf { csvn_free_string(buf) } }
            guard let buf, len > 0 else { return Data() }
            return Data(bytes: buf, count: len)
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
