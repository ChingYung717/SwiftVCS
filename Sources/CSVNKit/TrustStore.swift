import CryptoKit
import Darwin
import Foundation
import Security

/// libsvn 认证使用的源站标识，显式补齐协议的默认端口。
public struct SVNOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    /// 校验本地 `file://` 仓库 URL：要求主机与端口必须为空、无内嵌凭据/查询/片段且不含控制字符或 `%00`。
    public static func isValidLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              (url.host?.isEmpty ?? true) else {
            return false
        }
        let raw = url.absoluteString
        guard raw.rangeOfCharacter(from: .controlCharacters) == nil,
              !raw.lowercased().contains("%00") else {
            return false
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.user == nil,
              components.percentEncodedUser == nil,
              components.password == nil,
              components.percentEncodedPassword == nil,
              components.port == nil,
              components.query == nil,
              components.percentEncodedQuery == nil,
              components.fragment == nil,
              components.percentEncodedFragment == nil,
              (components.host?.isEmpty ?? true),
              components.path.hasPrefix("/"),
              components.path.rangeOfCharacter(from: .controlCharacters) == nil,
              !components.percentEncodedPath.lowercased().contains("%00") else {
            return false
        }
        return !url.path.isEmpty && url.path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let rawHost = url.host,
              !rawHost.isEmpty, !rawHost.contains("/"), !rawHost.contains("\0"),
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.user == nil || scheme == "svn+ssh" else { return nil }
        let raw = url.absoluteString
        guard raw.rangeOfCharacter(from: .controlCharacters) == nil,
              !raw.lowercased().contains("%00") else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.percentEncodedQuery == nil,
              components.fragment == nil,
              components.percentEncodedFragment == nil,
              components.password == nil,
              components.percentEncodedPassword == nil else { return nil }
        let cleanHost = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !cleanHost.isEmpty, !cleanHost.hasPrefix("-"),
              cleanHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              cleanHost.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if scheme == "svn+ssh" {
            if let encUser = components.percentEncodedUser,
               encUser.lowercased().contains("%00") {
                return nil
            }
            if components.percentEncodedUser != nil && components.user == nil {
                return nil
            }
            if let user = url.user {
                guard !user.isEmpty,
                      !user.hasPrefix("-"),
                      !user.contains("\0"),
                      !user.contains(":"),
                      !user.contains("@"),
                      !user.contains("/"),
                      user.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      user.rangeOfCharacter(from: .controlCharacters) == nil else {
                    return nil
                }
            }
        } else if components.user != nil || components.percentEncodedUser != nil {
            return nil
        }
        let defaultPort: Int
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        case "svn": defaultPort = 3690
        case "svn+ssh": defaultPort = 22
        default: return nil
        }
        let port = url.port ?? defaultPort
        guard (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = cleanHost
        self.port = port
    }

    public var endpoint: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
    public var authPrefix: String { "\(scheme)://\(endpoint)" }
}

/// 按 HTTPS 主机和端口保存人工核验过的叶证书。
public final class TrustStore: Sendable {
    public struct CertificateInfo: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let url: URL
        public let sha256Fingerprint: String

        public init(name: String, url: URL, sha256Fingerprint: String = "") {
            self.name = name
            self.url = url
            self.sha256Fingerprint = sha256Fingerprint
        }
    }

    /// 预抓取但尚未写入信任库的服务器证书信息（供用户先核对 SHA-256 指纹再决定是否信任）。
    public struct ProbedCertificate: Sendable, Hashable {
        public let host: String
        public let port: Int
        public let pemData: Data
        public let subjectSummary: String
        public let sha256Fingerprint: String

        public init(
            host: String,
            port: Int,
            pemData: Data,
            subjectSummary: String,
            sha256Fingerprint: String
        ) {
            self.host = host
            self.port = port
            self.pemData = pemData
            self.subjectSummary = subjectSummary
            self.sha256Fingerprint = sha256Fingerprint
        }
    }

    public static let shared = TrustStore()

    static let maxSecureReadBytes = 1024 * 1024

    public let root: URL
    private let certsDir: URL

    private convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(rootDirectory: home.appendingPathComponent(".config/vcs-explorer"))
    }

    public init(rootDirectory: URL) {
        root = rootDirectory
        certsDir = rootDirectory.appendingPathComponent("pinned-certs")
        try? Self.ensureSecureDirectory(at: root)
        try? Self.ensureSecureDirectory(at: certsDir)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private static func canonicalizeSystemPrefix(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] {
            if path == prefix {
                return "/private" + prefix
            }
            if path.hasPrefix(prefix + "/") {
                return "/private" + path
            }
        }
        return path
    }

    private static func isSafeSingleFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    /// 逐段以 `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开并校验安全目录链，返回叶目录 FD（调用方负责 `close`）。
    /// 当目标位于 `$HOME` 下时从 `realpath($HOME)` 开始逐段校验每个父目录（如 `~/.config`、`vcs-explorer`、`pinned-certs`）
    /// 均非符号链接、属主为当前用户且无组/其他写权限 (`(st_mode & 0o022) == 0`)。
    static func openSecureDirectoryFD(at dir: URL, create: Bool) throws -> Int32 {
        let euid = Darwin.geteuid()
        let rawDirPath = trimTrailingSlashes(dir.standardizedFileURL.path)
        guard rawDirPath.hasPrefix("/"), !rawDirPath.contains("\0") else {
            throw TrustStoreError.insecureStoragePath(dir.path)
        }

        let homeRaw = trimTrailingSlashes(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        let homeReal: String? = Darwin.realpath(homeRaw, nil).map { ptr in
            defer { free(ptr) }
            return trimTrailingSlashes(String(cString: ptr))
        }

        let anchorPath: String
        let relativeComponents: [String]
        let strictAllAncestors: Bool

        if let homeReal,
           (rawDirPath == homeRaw || rawDirPath.hasPrefix(homeRaw + "/") ||
            rawDirPath == homeReal || rawDirPath.hasPrefix(homeReal + "/")) {
            let matchedBase = (rawDirPath == homeRaw || rawDirPath.hasPrefix(homeRaw + "/")) ? homeRaw : homeReal
            let relStr = rawDirPath == matchedBase ? "" : String(rawDirPath.dropFirst(matchedBase.count + 1))
            anchorPath = homeReal
            relativeComponents = relStr.split(separator: "/").map(String.init)
            strictAllAncestors = true
        } else {
            let mapped = canonicalizeSystemPrefix(rawDirPath)
            anchorPath = "/"
            relativeComponents = mapped.split(separator: "/").map(String.init)
            strictAllAncestors = false
        }

        var curFD = Darwin.open(anchorPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard curFD >= 0 else {
            throw TrustStoreError.insecureStoragePath(dir.path)
        }
        var curSt = stat()
        guard Darwin.fstat(curFD, &curSt) == 0,
              (curSt.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(curFD)
            throw TrustStoreError.insecureStoragePath(dir.path)
        }
        if strictAllAncestors {
            guard curSt.st_uid == euid, (curSt.st_mode & 0o022) == 0 else {
                Darwin.close(curFD)
                throw TrustStoreError.insecureStoragePath(dir.path)
            }
        }

        for (idx, comp) in relativeComponents.enumerated() {
            guard isSafeSingleFilename(comp) else {
                Darwin.close(curFD)
                throw TrustStoreError.insecureStoragePath(dir.path)
            }
            let isLeaf = (idx == relativeComponents.count - 1)
            var nextFD = Darwin.openat(curFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if nextFD < 0 && errno == ENOENT && create {
                if Darwin.mkdirat(curFD, comp, 0o700) != 0 && errno != EEXIST {
                    Darwin.close(curFD)
                    throw TrustStoreError.insecureStoragePath(dir.path)
                }
                nextFD = Darwin.openat(curFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextFD >= 0 else {
                Darwin.close(curFD)
                throw TrustStoreError.insecureStoragePath(dir.path)
            }
            Darwin.close(curFD)
            curFD = nextFD

            var st = stat()
            guard Darwin.fstat(curFD, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(curFD)
                throw TrustStoreError.insecureStoragePath(dir.path)
            }
            if strictAllAncestors || isLeaf {
                guard st.st_uid == euid, (st.st_mode & 0o022) == 0 else {
                    Darwin.close(curFD)
                    throw TrustStoreError.insecureStoragePath(dir.path)
                }
            } else {
                let ownerOK = (st.st_uid == euid || st.st_uid == 0)
                let modeOK = (st.st_mode & 0o022) == 0 || (st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0)
                guard ownerOK && modeOK else {
                    Darwin.close(curFD)
                    throw TrustStoreError.insecureStoragePath(dir.path)
                }
            }
        }

        if create {
            guard Darwin.fchmod(curFD, 0o700) == 0 else {
                Darwin.close(curFD)
                throw TrustStoreError.insecureStoragePath(dir.path)
            }
        }
        return curFD
    }

    /// 在已校验的安全目录 FD 内以 `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` 有界读取普通文件（默认 1 MB 上限）。
    static func readSecureRegularFile(
        named fileName: String,
        inDirFD dirFD: Int32,
        maxBytes: Int = maxSecureReadBytes
    ) -> Data? {
        guard isSafeSingleFilename(fileName), maxBytes > 0 else { return nil }
        let fd = Darwin.openat(dirFD, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == Darwin.geteuid(),
              (st.st_mode & 0o022) == 0,
              st.st_nlink == 1,
              st.st_size >= 0,
              st.st_size <= Int64(maxBytes) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(min(Int(st.st_size), maxBytes))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let remaining = (maxBytes + 1) - data.count
            let toRead = min(buffer.count, remaining)
            let n = Darwin.read(fd, &buffer, toRead)
            if n > 0 {
                data.append(contentsOf: buffer[..<n])
                if data.count > maxBytes {
                    return nil
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    static func ensureSecureDirectory(at dir: URL) throws {
        let fd = try openSecureDirectoryFD(at: dir, create: true)
        Darwin.close(fd)
    }

    static func writeSecureAtomically(_ data: Data, to dest: URL, in dir: URL) throws {
        let fileName = dest.lastPathComponent
        guard isSafeSingleFilename(fileName) else {
            throw TrustStoreError.insecureStoragePath(dest.path)
        }
        let dirFD = try openSecureDirectoryFD(at: dir, create: true)
        defer { Darwin.close(dirFD) }

        var dstSt = stat()
        if Darwin.fstatat(dirFD, fileName, &dstSt, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (dstSt.st_mode & S_IFMT) == S_IFREG,
                  dstSt.st_uid == Darwin.geteuid(),
                  (dstSt.st_mode & 0o022) == 0 else {
                throw TrustStoreError.insecureStoragePath(dest.path)
            }
        } else if errno != ENOENT {
            throw TrustStoreError.insecureStoragePath(dest.path)
        }

        let tempName = ".\(fileName)-\(UUID().uuidString).tmp"
        let fd = Darwin.openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw TrustStoreError.insecureStoragePath(dir.appendingPathComponent(tempName).path)
        }
        var closed = false
        var renamed = false
        defer {
            if !closed { Darwin.close(fd) }
            if !renamed { _ = Darwin.unlinkat(dirFD, tempName, 0) }
        }

        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw TrustStoreError.insecureStoragePath(dir.appendingPathComponent(tempName).path)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw TrustStoreError.insecureStoragePath(dir.appendingPathComponent(tempName).path)
                }
            }
        }
        let closeRC = Darwin.close(fd)
        closed = true
        guard closeRC == 0 else {
            throw TrustStoreError.insecureStoragePath(dir.appendingPathComponent(tempName).path)
        }
        guard Darwin.renameat(dirFD, tempName, dirFD, fileName) == 0 else {
            throw TrustStoreError.insecureStoragePath(dest.path)
        }
        renamed = true
    }

    /// 计算证书数据（PEM 或 DER）的 SHA-256 指纹（格式如 `AA:BB:CC:...`）。
    public static func sha256Fingerprint(of data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let blocks = extractPEMBlocks(from: text)
        let derData: Data
        if let block = blocks.first, let decoded = Self.derData(fromPEMBlock: block) {
            derData = decoded
        } else {
            derData = data
        }
        guard !derData.isEmpty else { return "" }
        let digest = SHA256.hash(data: derData)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func isValidBase64Line(_ line: Substring) -> Bool {
        guard !line.isEmpty else { return false }
        for byte in line.utf8 {
            let ok = (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A)   // a-z
                || (byte >= 0x30 && byte <= 0x39)   // 0-9
                || byte == 0x2B                     // +
                || byte == 0x2F                     // /
                || byte == 0x3D                     // =
            if !ok { return false }
        }
        return true
    }

    /// 逐行严格匹配 PEM 边界（行锚定）并校验中间行均为合法 Base64，防止证书 Subject 文本内嵌 PEM 标记混淆。
    public static func extractPEMBlocks(from text: String) -> [String] {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        var blocks: [String] = []
        var inBlock = false
        var bodyLines: [String] = []

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inBlock {
                if rawLine == beginMarker {
                    inBlock = true
                    bodyLines.removeAll(keepingCapacity: true)
                }
                continue
            }

            if rawLine == endMarker {
                let joined = bodyLines.joined()
                if !joined.isEmpty, Data(base64Encoded: joined) != nil {
                    blocks.append(([beginMarker] + bodyLines + [endMarker]).joined(separator: "\n"))
                }
                inBlock = false
                bodyLines.removeAll(keepingCapacity: true)
            } else if rawLine == beginMarker {
                bodyLines.removeAll(keepingCapacity: true)
            } else if isValidBase64Line(rawLine) {
                bodyLines.append(String(rawLine))
            } else {
                inBlock = false
                bodyLines.removeAll(keepingCapacity: true)
            }
        }
        return blocks
    }

    private static func derData(fromPEMBlock block: String) -> Data? {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        let lines = block.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3, lines.first == Substring(beginMarker), lines.last == Substring(endMarker) else {
            return nil
        }
        let middle = lines.dropFirst().dropLast()
        guard middle.allSatisfy(isValidBase64Line) else { return nil }
        let body = middle.joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }

    public static func isSecureDirectory(_ dir: URL) -> Bool {
        guard let fd = try? openSecureDirectoryFD(at: dir, create: false) else {
            return false
        }
        Darwin.close(fd)
        return true
    }

    /// 已导入的内部证书。
    public func importedCertificates() -> [CertificateInfo] {
        guard Self.isSecureDirectory(root),
              let dirFD = try? Self.openSecureDirectoryFD(at: certsDir, create: false) else {
            return []
        }
        guard let dp = Darwin.fdopendir(dirFD) else {
            Darwin.close(dirFD)
            return []
        }
        defer { Darwin.closedir(dp) }

        let curFD = Darwin.dirfd(dp)
        var entries: [(fileName: String, info: CertificateInfo)] = []
        while let ent = Darwin.readdir(dp) {
            let fileName: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { cStr in
                    String(cString: cStr)
                }
            }
            guard fileName != ".", fileName != ".." else { continue }
            let ext = (fileName as NSString).pathExtension.lowercased()
            guard ext == "crt" || ext == "pem" else { continue }
            guard let data = Self.readSecureRegularFile(named: fileName, inDirFD: curFD) else {
                continue
            }
            let fileURL = certsDir.appendingPathComponent(fileName)
            let name = (fileName as NSString).deletingPathExtension
            let fp = Self.sha256Fingerprint(of: data)
            entries.append((fileName, CertificateInfo(name: name, url: fileURL, sha256Fingerprint: fp)))
        }
        return entries.sorted { $0.fileName < $1.fileName }.map(\.info)
    }

    public func trust(_ certificate: ProbedCertificate, for url: URL) throws {
        guard let origin = SVNOrigin(url), origin.scheme == "https",
              origin.host == certificate.host.lowercased(), origin.port == certificate.port,
              let der = Self.certificateDER(certificate.pemData),
              Self.sha256Fingerprint(of: der) == certificate.sha256Fingerprint else {
            throw TrustStoreError.notACertificate
        }
        try Self.ensureSecureDirectory(at: root)
        let dest = certsDir.appendingPathComponent("\(origin.endpoint).crt")
        try Self.writeSecureAtomically(der, to: dest, in: certsDir)
    }

    public func removeCertificate(name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              Self.isSafeSingleFilename(name) else {
            throw TrustStoreError.notACertificate
        }
        guard Self.isSecureDirectory(root) else {
            throw TrustStoreError.insecureStoragePath(root.path)
        }
        let dirFD = try Self.openSecureDirectoryFD(at: certsDir, create: false)
        defer { Darwin.close(dirFD) }
        for ext in ["crt", "pem"] {
            let fileName = "\(name).\(ext)"
            var st = stat()
            if Darwin.fstatat(dirFD, fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFREG else {
                    throw TrustStoreError.insecureStoragePath(certsDir.appendingPathComponent(fileName).path)
                }
                guard Darwin.unlinkat(dirFD, fileName, 0) == 0 || errno == ENOENT else {
                    throw TrustStoreError.insecureStoragePath(certsDir.appendingPathComponent(fileName).path)
                }
            } else if errno != ENOENT {
                throw TrustStoreError.insecureStoragePath(certsDir.appendingPathComponent(fileName).path)
            }
        }
    }

    public func pinnedCertificate(for origin: SVNOrigin) -> String? {
        guard origin.scheme == "https" else { return nil }
        guard Self.isSecureDirectory(root),
              let dirFD = try? Self.openSecureDirectoryFD(at: certsDir, create: false) else {
            return nil
        }
        defer { Darwin.close(dirFD) }
        let fileName = "\(origin.endpoint).crt"
        guard let data = Self.readSecureRegularFile(named: fileName, inDirFD: dirFD),
              let der = Self.certificateDER(data) else { return nil }
        return der.base64EncodedString()
    }

    private static func certificateDER(_ data: Data) -> Data? {
        let block = extractPEMBlocks(from: String(decoding: data, as: UTF8.self)).first
        let der = block.flatMap(derData(fromPEMBlock:)) ?? data
        return SecCertificateCreateWithData(nil, der as CFData) == nil ? nil : der
    }

    /// 预抓取服务器证书并提取主体摘要与 SHA-256 指纹，但不写入信任库（供界面展示指纹并由用户确认后再信任）。
    public func probeCertificate(host: String, port: Int = 443) throws -> ProbedCertificate {
        guard !host.isEmpty,
              !host.hasPrefix("-"),
              !host.contains("\0"),
              !host.contains("/"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              (1...65535).contains(port) else {
            throw TrustStoreError.cannotFetchCertificate
        }
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let ipv4Parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPLiteral = host.contains(":") || (ipv4Parts.count == 4 && ipv4Parts.allSatisfy { UInt8($0) != nil })
        var args = ["s_client", "-connect", address]
        if !isIPLiteral {
            args.append(contentsOf: ["-servername", host])
        }
        args.append("-showcerts")
        let pem = try runOpenssl(args)
        let blocks = Self.extractPEMBlocks(from: pem)
        guard let targetCertBlock = blocks.first,
              let der = Self.derData(fromPEMBlock: targetCertBlock),
              let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TrustStoreError.cannotFetchCertificate
        }
        let pemData = Data((targetCertBlock + "\n").utf8)
        let summary = (SecCertificateCopySubjectSummary(secCert) as String?) ?? host
        let fp = Self.sha256Fingerprint(of: pemData)
        return ProbedCertificate(
            host: host,
            port: port,
            pemData: pemData,
            subjectSummary: summary,
            sha256Fingerprint: fp
        )
    }

    @discardableResult
    private func runOpenssl(_ args: [String], maxOutputBytes: Int = 256 * 1024) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = args
        let pipe = Pipe()
        // 关键：s_client 若不把 stdin 重定向到 /dev/null，握手后会一直阻塞等待输入！
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw TrustStoreError.opensslUnavailable }

        let timeoutWork = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutWork)

        // 有界分块读取，防止恶意 TLS 服务端持续灌入数据造成 OOM。
        let reader = pipe.fileHandleForReading
        var data = Data()
        var exceeded = false
        while true {
            let chunk = (try? reader.read(upToCount: 16_384)) ?? Data()
            if chunk.isEmpty { break }
            let remaining = maxOutputBytes - data.count
            if chunk.count > remaining {
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                exceeded = true
                if task.isRunning { task.terminate() }
                break
            }
            data.append(chunk)
        }
        try? reader.close()
        task.waitUntilExit()
        timeoutWork.cancel()
        if exceeded && data.isEmpty {
            throw TrustStoreError.cannotFetchCertificate
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum TrustStoreError: Error, LocalizedError {
    case notACertificate
    case cannotFetchCertificate
    case opensslUnavailable
    case insecureStoragePath(String)

    public var errorDescription: String? {
        switch self {
        case .notACertificate: return "不是有效的 PEM/DER 证书"
        case .cannotFetchCertificate: return "无法获取服务器证书"
        case .opensslUnavailable: return "系统 openssl 不可用"
        case .insecureStoragePath(let path): return "证书或配置存储路径不安全（拒绝符号链接或非当前用户属主）：\(path)"
        }
    }
}

// MARK: - 钥匙串

public enum KeychainStore {
    struct SavedPassword: Codable {
        let password: String
        let realm: String
    }

    public static func service(for url: URL) -> String? {
        guard let origin = SVNOrigin(url), origin.scheme == "https",
              url.query == nil, url.fragment == nil else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let canonicalPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        return "local.vcsexplorer.svn.v2|\(origin.authPrefix)\(canonicalPath)"
    }

    private static func query(service: String, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: username]
    }

    private static func read(service: String, username: String) throws -> Data? {
        var request = query(service: service, username: username)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status) }
        return result as? Data
    }

    static func load(url: URL, username: String) throws -> SavedPassword? {
        guard let service = service(for: url),
              let data = try read(service: service, username: username) else { return nil }
        return try JSONDecoder().decode(SavedPassword.self, from: data)
    }

    static func loadReference(service: String, username: String, url: URL) throws -> SavedPassword? {
        if service == self.service(for: url) {
            return try load(url: url, username: username)
        }
        return nil
    }

    static func save(url: URL, username: String, password: String, realm: String) throws {
        guard let service = service(for: url) else { return }
        let data = try JSONEncoder().encode(SavedPassword(password: password, realm: realm))
        var request = query(service: service, username: username)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(service: service, username: username) as CFDictionary,
                                   attrs as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status) }
    }

    public static func delete(url: URL, username: String) throws {
        guard let service = service(for: url) else { return }
        let status = SecItemDelete(query(service: service, username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case operationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "无法访问 macOS 钥匙串：\(message)"
        }
    }
}

// MARK: - URL 凭据清洗与脱敏

/// 负责在持久化、UI 展示、复制与日志输出前清洗或脱敏仓库 URL。
/// - 持久化规则（`sanitizeForPersistence`）：
///   - 剥离所有协议中的 `password`；
///   - 剥离 `https`、`http`、`svn`、`file` 等不需要 URL 内嵌 userinfo 的协议中的 `user`；
///   - 保留 `svn+ssh://user@host/path` 中合法的 SSH 用户名（因其属于 SSH 连接目标语义，同时剥离可能误填的口令）；
///   - 对无法解析、缺少合法主机或 authority 中存在多重 `@`（如未编码的口令含 `@`）的输入返回 `nil`，拒绝落盘。
public enum SVNURLSanitizer {
    public static func sanitizeForPersistence(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
           trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            return nil
        }
        var pctIdx = trimmed.startIndex
        while pctIdx < trimmed.endIndex {
            if trimmed[pctIdx] == "%" {
                let h1 = trimmed.index(after: pctIdx)
                guard h1 < trimmed.endIndex else { return nil }
                let h2 = trimmed.index(after: h1)
                guard h2 < trimmed.endIndex,
                      trimmed[h1].isHexDigit,
                      trimmed[h2].isHexDigit else {
                    return nil
                }
                pctIdx = trimmed.index(after: h2)
            } else {
                pctIdx = trimmed.index(after: pctIdx)
            }
        }

        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        let rawScheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
        let afterScheme = trimmed[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let rawAuthority = String(afterScheme[..<authorityEnd])
        let afterAuthority = afterScheme[authorityEnd...]

        // 若 authority 中出现多个字面量 '@'（例如未编码密码中包含 '@'），或口令中含未编码 '/' 导致 '@host' 落入 path，拒绝落盘
        if rawAuthority.filter({ $0 == "@" }).count > 1 {
            return nil
        }
        if afterAuthority.contains("@") {
            let firstSegment = afterAuthority.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
            if rawAuthority.contains(":") || rawAuthority.contains("@") || firstSegment?.contains("@") == true {
                return nil
            }
        }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == rawScheme else {
            return nil
        }
        guard components.query == nil, components.percentEncodedQuery == nil,
              components.fragment == nil, components.percentEncodedFragment == nil else {
            return nil
        }
        if components.path.rangeOfCharacter(from: .controlCharacters) != nil ||
           components.percentEncodedPath.lowercased().contains("%00") {
            return nil
        }

        switch scheme {
        case "file":
            components.scheme = "file"
            components.percentEncodedUser = nil
            components.percentEncodedPassword = nil
            guard components.port == nil else { return nil }
            if let host = components.host, !host.isEmpty {
                return nil
            }
            components.host = ""
            var path = components.percentEncodedPath
            guard path.hasPrefix("/") else { return nil }
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            components.percentEncodedPath = path
            guard let url = components.url, SVNOrigin.isValidLocalFileURL(url) else {
                return nil
            }
            return url.absoluteString

        case "https", "http", "svn", "svn+ssh":
            components.scheme = scheme
            components.percentEncodedPassword = nil
            if scheme == "svn+ssh" {
                if let user = components.user {
                    if user.isEmpty ||
                       user.hasPrefix("-") ||
                       user.contains(":") ||
                       user.contains("@") ||
                       user.contains("/") ||
                       user.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
                       user.rangeOfCharacter(from: .controlCharacters) != nil {
                        return nil
                    }
                } else if components.percentEncodedUser != nil {
                    return nil
                }
            } else {
                components.percentEncodedUser = nil
            }
            if let host = components.host, host.hasPrefix("-") {
                return nil
            }

            // 校验去除 userinfo 后的原始主机写法（非 IPv6 字面量不得含额外冒号）
            let hostPortSub: Substring
            if let atIdx = rawAuthority.lastIndex(of: "@") {
                hostPortSub = rawAuthority[rawAuthority.index(after: atIdx)...]
            } else {
                hostPortSub = rawAuthority[...]
            }
            if !hostPortSub.isEmpty {
                if hostPortSub.first == "[" {
                    guard let closeIdx = hostPortSub.firstIndex(of: "]") else { return nil }
                    let remainder = hostPortSub[hostPortSub.index(after: closeIdx)...]
                    if !remainder.isEmpty && !remainder.hasPrefix(":") {
                        return nil
                    }
                } else {
                    if hostPortSub.filter({ $0 == ":" }).count > 1 {
                        return nil
                    }
                }
            } else {
                return nil
            }

            var path = components.percentEncodedPath
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            if path == "/" {
                path = ""
            }
            components.percentEncodedPath = path

            guard let cleanURL = components.url,
                  cleanURL.password == nil,
                  cleanURL.user == nil || scheme == "svn+ssh",
                  SVNOrigin(cleanURL) != nil else {
                return nil
            }
            return cleanURL.absoluteString

        default:
            return nil
        }
    }

    /// 用于 UI、剪贴板或状态栏展示的脱敏字符串：若可合法清洗则返回清洗结果，否则隐藏一切疑似凭据片段。
    public static func redactForDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let clean = sanitizeForPersistence(trimmed) {
            return clean
        }
        return redactCredentials(inMessage: trimmed)
    }

    private static func redactAuthHeaders(in text: String) -> String {
        guard text.localizedCaseInsensitiveContains("authorization:") else { return text }
        let utf8 = Array(text.utf8)
        let count = utf8.count
        var out: [UInt8] = []
        out.reserveCapacity(count)

        let proxyPrefix = Array("proxy-authorization:".utf8)
        let authPrefix = Array("authorization:".utf8)
        let redactedBytes = Array("<redacted>".utf8)

        func isIdentifierChar(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) ||
            (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2D
        }
        func matchesCI(at idx: Int, prefix: [UInt8]) -> Bool {
            guard idx + prefix.count <= count else { return false }
            for k in 0..<prefix.count {
                var c = utf8[idx + k]
                if c >= 0x41 && c <= 0x5A { c += 32 }
                if c != prefix[k] { return false }
            }
            return true
        }

        var i = 0
        while i < count {
            let boundaryOK = (i == 0) || !isIdentifierChar(utf8[i - 1])
            var hdrLen = 0
            if boundaryOK {
                if matchesCI(at: i, prefix: proxyPrefix) {
                    hdrLen = proxyPrefix.count
                } else if matchesCI(at: i, prefix: authPrefix) {
                    hdrLen = authPrefix.count
                }
            }
            guard hdrLen > 0 else {
                out.append(utf8[i])
                i += 1
                continue
            }

            let closeDelim: UInt8?
            if i > 0 {
                switch utf8[i - 1] {
                case 0x28: closeDelim = 0x29 // '(' -> ')'
                case 0x5B: closeDelim = 0x5D // '[' -> ']'
                case 0x27: closeDelim = 0x27 // '\''
                case 0x22: closeDelim = 0x22 // '"'
                default: closeDelim = nil
                }
            } else {
                closeDelim = nil
            }

            out.append(contentsOf: utf8[i..<(i + hdrLen)])
            i += hdrLen
            while i < count && (utf8[i] == 0x20 || utf8[i] == 0x09) {
                out.append(utf8[i])
                i += 1
            }
            let valStart = i
            while i < count && utf8[i] != 0x0D && utf8[i] != 0x0A {
                if let closeDelim, utf8[i] == closeDelim {
                    break
                }
                i += 1
            }
            if i > valStart {
                out.append(contentsOf: redactedBytes)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 脱敏任意日志或错误消息中形如 `scheme://user:pass@host`、`//user:pass@host`、`user:pass@` 或 `Authorization:` 头的内嵌凭据。
    public static func redactCredentials(inMessage message: String) -> String {
        var result = message
        if result.contains("@") {
            let schemePatterns = [
                // 1. 含 scheme，且 user:pass 中口令可能包含 '/'、'?'、'#'、'@'、引号等，后跟合法主机名/IPv6/端口/路径或闭合标点 ),;]
                #"([a-zA-Z][a-zA-Z0-9+.-]*://)([^\s/:<>"']+):((?:(?!://)[^\s<>])+)@(?=(?:\[[0-9a-fA-F:]+\]|localhost|[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+|[a-zA-Z0-9.-]+:\d+|[a-zA-Z0-9.-]+/)(?::\d+)?(?:[/\s<>"'),;\]]|$))"#,
                // 2. 含 scheme，首个 '/' 前的任意 userinfo（允许含 '?'、'#'、'@'）
                #"([a-zA-Z][a-zA-Z0-9+.-]*://)([^\s/<>"']+)@"#,
                // 2b. 协议相对 URL：//user:pass@host
                #"(^|[\s(\[<,;'\"=])(//)([^\s/:<>"']+):((?:(?!://)[^\s<>])+)@(?=(?:\[[0-9a-fA-F:]+\]|localhost|[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+|[a-zA-Z0-9.-]+:\d+|[a-zA-Z0-9.-]+/)(?::\d+)?(?:[/\s<>"'),;\]]|$))"#,
            ]
            for (idx, pattern) in schemePatterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(
                        in: result,
                        options: [],
                        range: nsRange,
                        withTemplate: idx == 2 ? "$1$2<redacted>@" : "$1<redacted>@"
                    )
                }
            }
            let fallbackPatterns = [
                // 3. 不含 scheme 的 user:pass@host（允许口令中含 '/'、'?'、'#'、'@'，后跟主机名/IPv6/端口/路径或闭合标点 ),;]）
                #"([^\s:/?#<>"']+):([^\s<>"']+)@(?=(?:\[[0-9a-fA-F:]+\]|localhost|[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+|[a-zA-Z0-9.-]+:\d+|[a-zA-Z0-9.-]+/)(?::\d+)?(?:[/\s<>"'),;\]]|$))"#,
                // 4. 不含 scheme 的 user:pass@（允许口令中含 '?'、'#'、'@'，不含 '/'）
                #"([^\s:/?#<>"']+):([^\s/<>"']+)@"#,
            ]
            for pattern in fallbackPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                    result = regex.stringByReplacingMatches(
                        in: result,
                        options: [],
                        range: nsRange,
                        withTemplate: "<redacted>@"
                    )
                }
            }
        }
        return redactAuthHeaders(in: result)
    }
}

// MARK: - 客户端配置持久化

/// 保存最近连接的仓库 URL、用户名与本地工作副本路径（`~/.config/vcs-explorer/settings.json`）。
public struct AppSettings: Codable, Equatable, Sendable {
    public var repoURL: String
    public var username: String
    public var workingCopyPath: String
    public var rememberPassword: Bool
    public var recentRepos: [String]

    enum CodingKeys: String, CodingKey {
        case repoURL
        case username
        case workingCopyPath
        case rememberPassword
        case recentRepos
    }

    public init(
        repoURL: String = "",
        username: String = "",
        workingCopyPath: String = "",
        rememberPassword: Bool = false,
        recentRepos: [String] = []
    ) {
        self.repoURL = repoURL
        self.username = username
        self.workingCopyPath = workingCopyPath
        self.rememberPassword = rememberPassword
        self.recentRepos = recentRepos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repoURL = try container.decodeIfPresent(String.self, forKey: .repoURL) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.workingCopyPath = try container.decodeIfPresent(String.self, forKey: .workingCopyPath) ?? ""
        self.rememberPassword = try container.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? false
        self.recentRepos = try container.decodeIfPresent([String].self, forKey: .recentRepos) ?? []
    }

    /// 返回经 URL 凭据清洗与最近仓库去重（最多保留 8 条）后的安全配置副本。
    public func sanitized() -> AppSettings {
        let cleanRepoURL = SVNURLSanitizer.sanitizeForPersistence(repoURL) ?? ""
        var seen = Set<String>()
        var cleanRecents: [String] = []
        for item in recentRepos {
            guard let cleanItem = SVNURLSanitizer.sanitizeForPersistence(item),
                  !cleanItem.isEmpty else { continue }
            if seen.insert(cleanItem).inserted {
                cleanRecents.append(cleanItem)
                if cleanRecents.count >= 8 {
                    break
                }
            }
        }
        return AppSettings(
            repoURL: cleanRepoURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            workingCopyPath: workingCopyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            rememberPassword: rememberPassword,
            recentRepos: cleanRecents
        )
    }
}

public enum AppSettingsStoreError: Error, LocalizedError, Sendable {
    case temporaryFileCreationFailed(String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .temporaryFileCreationFailed(let path):
            return "无法创建设置临时文件：\(path)"
        case .persistenceFailed(let reason):
            return "无法保存客户端设置：\(reason)"
        }
    }
}

public enum AppSettingsStore {
    private static let errorLock = NSLock()
    private static var _lastError: String?

    public static var lastError: String? {
        get {
            errorLock.lock()
            defer { errorLock.unlock() }
            return _lastError
        }
        set {
            errorLock.lock()
            defer { errorLock.unlock() }
            _lastError = newValue
        }
    }

    public static var defaultSettingsURL: URL {
        TrustStore.shared.root.appendingPathComponent("settings.json")
    }

    public static func load(from fileURL: URL? = nil) -> AppSettings {
        let targetURL = fileURL ?? defaultSettingsURL
        let parentDir = targetURL.deletingLastPathComponent()
        let fileName = targetURL.lastPathComponent
        guard let dirFD = try? TrustStore.openSecureDirectoryFD(at: parentDir, create: false) else {
            return AppSettings(repoURL: "", username: "", workingCopyPath: "", rememberPassword: false, recentRepos: [])
        }
        defer { Darwin.close(dirFD) }
        guard let data = TrustStore.readSecureRegularFile(named: fileName, inDirFD: dirFD),
              let raw = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(repoURL: "", username: "", workingCopyPath: "", rememberPassword: false, recentRepos: [])
        }
        let clean = raw.sanitized()
        let rawText = String(decoding: data, as: UTF8.self)
        let needsMigrationRewrite = (clean != raw) || rawText.contains("@") && {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let encoded = try? encoder.encode(clean) else { return true }
            return String(decoding: encoded, as: UTF8.self) != rawText
        }()
        if needsMigrationRewrite {
            do {
                try saveThrowing(clean, to: targetURL)
            } catch {
                lastError = SVNURLSanitizer.redactCredentials(inMessage: error.localizedDescription)
            }
        }
        return clean
    }

    public static func saveThrowing(_ settings: AppSettings, to fileURL: URL? = nil) throws {
        let targetURL = fileURL ?? defaultSettingsURL
        let clean = settings.sanitized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clean)
        let rootDir = targetURL.deletingLastPathComponent()
        do {
            try TrustStore.writeSecureAtomically(data, to: targetURL, in: rootDir)
            lastError = nil
        } catch {
            let redacted = SVNURLSanitizer.redactCredentials(inMessage: error.localizedDescription)
            lastError = redacted
            throw AppSettingsStoreError.persistenceFailed(redacted)
        }
    }

    public static func save(_ settings: AppSettings, to fileURL: URL? = nil) {
        do {
            try saveThrowing(settings, to: fileURL)
        } catch {
            let redacted = SVNURLSanitizer.redactCredentials(inMessage: error.localizedDescription)
            lastError = redacted
            fputs("[AppSettingsStore] \(redacted)\n", stderr)
        }
    }
}

