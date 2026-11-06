import CryptoKit
import Foundation
import Security

/// 证书信任库：管理内部服务器的自签名 CA。
///
/// libsvn 的 serf 后端用 OpenSSL 校验 TLS，`SSL_CTX_set_default_verify_paths()`
/// 会读取 `SSL_CERT_FILE` 环境变量。因此把「系统根证书 + 用户导入的内部 CA」
/// 合并成一个 bundle 并设置该环境变量，即可让内部服务器被信任，而不影响其它站点。
public final class TrustStore: @unchecked Sendable {

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
    private let bundleURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = home.appendingPathComponent(".config/vcs-explorer")
        certsDir = root.appendingPathComponent("certs")
        bundleURL = root.appendingPathComponent("ca-bundle.crt")
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

    /// 系统根证书包（macOS 自带）。
    private static let systemBundles = [
        "/etc/ssl/cert.pem",
        "/opt/homebrew/etc/openssl@3/certs/ca-certificates.crt",
    ]

    public var caBundleURL: URL { bundleURL }

    /// 计算证书数据（PEM 或 DER）的 SHA-256 指纹（格式如 `AA:BB:CC:...`）。
    public static func sha256Fingerprint(of data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let blocks = extractPEMBlocks(from: text)
        let derData: Data
        if let block = blocks.last ?? blocks.first, let decoded = Self.derData(fromPEMBlock: block) {
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

    /// 导入一张 PEM/DER 证书。
    public func addCertificate(pem data: Data, name: String) throws {
        var text = String(decoding: data, as: UTF8.self)

        if !text.contains("BEGIN CERTIFICATE") {
            // 认为是 DER，用 openssl 转成 PEM
            let tmp = root.appendingPathComponent(".import-\(UUID().uuidString).der")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let converted = try runOpenssl(["x509", "-inform", "DER", "-in", tmp.path])
            text = converted
        }

        let blocks = Self.extractPEMBlocks(from: text)
        let validBlocks = blocks.filter { block in
            guard let der = Self.derData(fromPEMBlock: block), !der.isEmpty else { return false }
            return SecCertificateCreateWithData(nil, der as CFData) != nil
        }
        guard !validBlocks.isEmpty else {
            throw TrustStoreError.notACertificate
        }
        let normalized = validBlocks.joined(separator: "\n") + "\n"

        let safe = sanitized(name)
        guard !safe.isEmpty else {
            throw TrustStoreError.notACertificate
        }
        let dest = certsDir.appendingPathComponent("\(safe).crt")
        try normalized.write(to: dest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        try rebuildBundle()
    }

    public func removeCertificate(name: String) throws {
        let dest = certsDir.appendingPathComponent("\(sanitized(name)).crt")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try rebuildBundle()
    }

    /// 重建 bundle = 系统根证书 + 所有导入的内部证书。
    public func rebuildBundle() throws {
        var combined = Data()
        var wroteAny = false
        for p in Self.systemBundles where FileManager.default.fileExists(atPath: p) {
            combined.append(try Data(contentsOf: URL(fileURLWithPath: p)))
            combined.append(Data("\n".utf8))
            wroteAny = true
            break
        }
        for c in importedCertificates() {
            combined.append(try Data(contentsOf: c.url))
            combined.append(Data("\n".utf8))
        }
        guard wroteAny else { return }
        try combined.write(to: bundleURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
    }

    /// 让当前进程信任该 bundle（必须在任何 TLS 会话建立之前调用）。
    public func install() {
        try? rebuildBundle()
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return }
        setenv("SSL_CERT_FILE", bundleURL.path, 1)
    }

    /// 预抓取服务器证书并提取主体摘要与 SHA-256 指纹，但不写入信任库（供界面展示指纹并由用户确认后再信任）。
    public func probeCertificate(host: String, port: Int = 443) throws -> ProbedCertificate {
        let pem = try runOpenssl([
            "s_client", "-connect", "\(host):\(port)", "-servername", host, "-showcerts",
        ])
        let blocks = Self.extractPEMBlocks(from: pem)
        let validBlocks = blocks.filter { block in
            guard let der = Self.derData(fromPEMBlock: block), !der.isEmpty else { return false }
            return SecCertificateCreateWithData(nil, der as CFData) != nil
        }
        guard let targetCertBlock = validBlocks.last,
              !targetCertBlock.isEmpty,
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

    /// 从服务器抓取其证书并导入（用于自签名场景）。
    /// 只保存服务器证书链中的自签名根/颁发者证书（最后一个 PEM 块）或叶子证书，并校验证书非空。
    @discardableResult
    public func fetchCertificate(host: String, port: Int = 443) throws -> String {
        let probed = try probeCertificate(host: host, port: port)
        try addCertificate(pem: probed.pemData, name: host)
        return host
    }

    // MARK: - 内部

    private func sanitized(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return String(s.unicodeScalars.filter { allowed.contains($0) })
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

// MARK: - 钥匙串与凭据存储

/// 凭据安全存储（`~/.config/vcs-explorer/credentials.json`，权限 `0600`）。
///
/// 说明：由于 `vcsctl`、Debug 版 `VCSExplorer` 与打包后的 `dist/VCSExplorer.app` 使用
/// ad-hoc 签名（无付费开发者 Team ID），各二进制拥有不同的 CDHash。若直接写入系统
/// Legacy Keychain (`login.keychain-db`)，跨进程或重新打包后读取会触发 `SecurityAgent`
/// 模态授权弹窗并阻塞 GUI/CLI 线程。因此这里将凭据以 0600 权限保存在用户私密配置目录中。
public enum KeychainStore {

    private static var storeFileURL: URL {
        TrustStore.shared.root.appendingPathComponent("credentials.json")
    }

    public static func save(username: String, password: String, server: String) throws {
        var map = readMap()
        map["\(server)|\(username)"] = password
        try writeMap(map)
    }

    public static func load(server: String, username: String) -> String? {
        readMap()["\(server)|\(username)"]
    }

    public static func delete(server: String, username: String) {
        var map = readMap()
        map.removeValue(forKey: "\(server)|\(username)")
        try? writeMap(map)
    }

    /// 列出某服务器已保存的用户名（不含密码）。
    public static func listAccounts(server: String) -> [String] {
        var result: [String] = []
        for key in readMap().keys.sorted() where key.hasPrefix(server + "|") {
            let u = String(key.dropFirst(server.count + 1))
            if !result.contains(u) { result.append(u) }
        }
        return result
    }

    private static func readMap() -> [String: String] {
        guard let data = try? Data(contentsOf: storeFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeMap(_ map: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        let rootDir = TrustStore.shared.root
        try FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDir.path
        )

        let tempURL = rootDir.appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        let created = FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            _ = try FileManager.default.replaceItemAt(storeFileURL, withItemAt: tempURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeFileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case unableToSave(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unableToSave(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "未知错误"
            return "无法保存到钥匙串：\(msg)"
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
        rememberPassword: Bool = true,
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
            return AppSettings(repoURL: "", username: "", workingCopyPath: "", rememberPassword: true, recentRepos: [])
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
