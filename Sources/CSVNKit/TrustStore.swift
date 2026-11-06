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
        let pem = try runOpenssl([
            "s_client", "-connect", address, "-servername", host, "-showcerts",
        ])
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
        let attrs = [kSecValueData as String: data]
        request[kSecValueData as String] = data
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

// MARK: - 客户端配置持久化

/// 保存最近连接的仓库 URL、用户名与本地工作副本路径（`~/.config/vcs-explorer/settings.json`）。
public struct AppSettings: Codable, Sendable {
    public var repoURL: String
    public var username: String
    public var workingCopyPath: String
    public var rememberPassword: Bool
    public var recentRepos: [String]

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
}

public enum AppSettingsStore {
    private static var settingsURL: URL {
        TrustStore.shared.root.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings(repoURL: "", username: "", workingCopyPath: "", rememberPassword: false, recentRepos: [])
        }
        return s
    }

    public static func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let rootDir = TrustStore.shared.root
        try? FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDir.path)
        let tempURL = rootDir.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        if FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) {
            _ = try? FileManager.default.replaceItemAt(settingsURL, withItemAt: tempURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
