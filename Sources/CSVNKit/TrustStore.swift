import CryptoKit
import Foundation
import Security

/// libsvn 认证使用的源站标识，显式补齐协议的默认端口。
public struct SVNOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host,
              !host.isEmpty, !host.contains("/"), url.password == nil,
              url.user == nil || scheme == "svn+ssh" else { return nil }
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
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        self.port = port
    }

    public var endpoint: String { "\(host):\(port)" }
    var authPrefix: String { "\(scheme)://\(endpoint)" }
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

    public let root: URL
    private let certsDir: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = home.appendingPathComponent(".config/vcs-explorer")
        certsDir = root.appendingPathComponent("pinned-certs")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.createDirectory(
            at: certsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: certsDir.path)
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

    private static func extractPEMBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        while let begin = text.range(of: beginMarker, range: searchRange),
              let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) {
            blocks.append(String(text[begin.lowerBound..<end.upperBound]))
            searchRange = end.upperBound..<text.endIndex
        }
        return blocks
    }

    private static func derData(fromPEMBlock block: String) -> Data? {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        guard let begin = block.range(of: beginMarker),
              let end = block.range(of: endMarker, range: begin.upperBound..<block.endIndex) else {
            return nil
        }
        let body = block[begin.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }

    /// 已导入的内部证书。
    public func importedCertificates() -> [CertificateInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: certsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "crt" || $0.pathExtension == "pem" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { fileURL in
                let name = fileURL.deletingPathExtension().lastPathComponent
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                let fp = Self.sha256Fingerprint(of: data)
                return CertificateInfo(name: name, url: fileURL, sha256Fingerprint: fp)
            }
    }

    public func trust(_ certificate: ProbedCertificate, for url: URL) throws {
        guard let origin = SVNOrigin(url), origin.scheme == "https",
              origin.host == certificate.host.lowercased(), origin.port == certificate.port,
              let der = Self.certificateDER(certificate.pemData),
              Self.sha256Fingerprint(of: der) == certificate.sha256Fingerprint else {
            throw TrustStoreError.notACertificate
        }
        let dest = certsDir.appendingPathComponent("\(origin.endpoint).crt")
        try der.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }

    public func removeCertificate(name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty else {
            throw TrustStoreError.notACertificate
        }
        let dest = certsDir.appendingPathComponent("\(name).crt")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }

    func pinnedCertificate(for origin: SVNOrigin) -> String? {
        guard origin.scheme == "https",
              let data = try? Data(contentsOf: certsDir.appendingPathComponent("\(origin.endpoint).crt")),
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
        guard !host.isEmpty, !host.hasPrefix("-"), (1...65535).contains(port) else {
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
    private func runOpenssl(_ args: [String]) throws -> String {
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeoutWork.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum TrustStoreError: Error, LocalizedError {
    case notACertificate
    case cannotFetchCertificate
    case opensslUnavailable

    public var errorDescription: String? {
        switch self {
        case .notACertificate: return "不是有效的 PEM/DER 证书"
        case .cannotFetchCertificate: return "无法获取服务器证书"
        case .opensslUnavailable: return "系统 openssl 不可用"
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
        guard components.query == nil, components.fragment == nil else {
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
            if let host = components.host, !host.isEmpty && host.lowercased() != "localhost" {
                return nil
            }
            components.host = ""
            var path = components.percentEncodedPath
            guard path.hasPrefix("/") else { return nil }
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            components.percentEncodedPath = path
            guard let url = components.url, url.isFileURL,
                  url.user == nil, url.password == nil else {
                return nil
            }
            return url.absoluteString

        case "https", "http", "svn", "svn+ssh":
            components.scheme = scheme
            components.percentEncodedPassword = nil
            if scheme == "svn+ssh" {
                if let user = components.user {
                    if user.isEmpty ||
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

    /// 脱敏任意日志或错误消息中形如 `scheme://user:pass@host` 或 `user:pass@` 的内嵌凭据。
    public static func redactCredentials(inMessage message: String) -> String {
        guard message.contains("@") else { return message }
        var result = message
        let schemePatterns = [
            // 1. 含 scheme，且 user:pass 中口令可能包含 '/'、'?'、'#'、'@'，后跟合法主机名/IPv6/端口/路径
            #"([a-zA-Z][a-zA-Z0-9+.-]*://)([^\s/:<>"']+):([^\s<>"']+)@(?=(?:\[[0-9a-fA-F:]+\]|localhost|[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+|[a-zA-Z0-9.-]+:\d+|[a-zA-Z0-9.-]+/)(?::\d+)?(?:[/\s<>"']|$))"#,
            // 2. 含 scheme，首个 '/' 前的任意 userinfo（允许含 '?'、'#'、'@'）
            #"([a-zA-Z][a-zA-Z0-9+.-]*://)([^\s/<>"']+)@"#,
        ]
        for pattern in schemePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: nsRange,
                    withTemplate: "$1<redacted>@"
                )
            }
        }
        let fallbackPatterns = [
            // 3. 不含 scheme 的 user:pass@host（允许口令中含 '/'、'?'、'#'、'@'，后跟主机名/IPv6/端口/路径）
            #"([^\s:/?#<>"']+):([^\s<>"']+)@(?=(?:\[[0-9a-fA-F:]+\]|localhost|[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+|[a-zA-Z0-9.-]+:\d+|[a-zA-Z0-9.-]+/)(?::\d+)?(?:[/\s<>"']|$))"#,
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
        return result
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
        guard let data = try? Data(contentsOf: targetURL),
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
        let fm = FileManager.default
        try fm.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDir.path)

        let tempURL = rootDir.appendingPathComponent(".\(targetURL.lastPathComponent)-\(UUID().uuidString).tmp")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        guard fm.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AppSettingsStoreError.temporaryFileCreationFailed(tempURL.path)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        do {
            if fm.fileExists(atPath: targetURL.path) {
                _ = try fm.replaceItemAt(targetURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: targetURL)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
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

