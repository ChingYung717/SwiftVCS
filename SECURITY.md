# Security Policy / 安全策略

## 简体中文

### 安全架构说明
1. **TLS / SSL 证书校验**：
   - `SwiftVCS` 默认使用系统根证书包（`/etc/ssl/cert.pem`）验证 HTTPS 服务器证书。
   - 对于使用自签名证书或企业内部私有 CA 的 SVN 服务器，`VCS Explorer` 采用「两步指纹核验机制」：先通过 [`TrustStore.probeCertificate`](Sources/CSVNKit/TrustStore.swift) 提取证书主体（Subject）与 `SHA-256` 指纹展示给用户，仅在用户人工核对确认后才将证书合并至 `~/.config/vcs-explorer/ca-bundle.crt`（权限 `0600`）。
2. **本地凭据保护**：
   - 配置目录 `~/.config/vcs-explorer` 权限强制设为 `0700`。
   - 凭据文件 `~/.config/vcs-explorer/credentials.json` 采用 `0600` 权限临时文件创建并通过原子替换（`replaceItemAt`）写入，仅当前登录的 macOS 用户可读。

### 报告安全漏洞
如发现任何安全隐患（如命令注入、证书绕过、内存越界或凭据泄露风险），请勿在公开 Issue 中直接披露攻击细节，请通过 GitHub Security Advisories 私密提交报告。

---

## English

### Security Architecture
1. **TLS / SSL Certificate Verification**:
   - By default, `SwiftVCS` validates HTTPS connections against the system root CA bundle (`/etc/ssl/cert.pem`).
   - For enterprise SVN servers with self-signed certificates or internal CAs, `VCS Explorer` enforces a **two-step SHA-256 fingerprint verification flow**: the certificate is probed first via [`TrustStore.probeCertificate`](Sources/CSVNKit/TrustStore.swift), displaying the Subject and `SHA-256` fingerprint in the UI, and is only written to `~/.config/vcs-explorer/ca-bundle.crt` (`0600`) after explicit user confirmation.
2. **Local Credential Storage**:
   - The configuration directory `~/.config/vcs-explorer` is created with `0700` permissions.
   - `~/.config/vcs-explorer/credentials.json` is written atomically via a temporary file created with `0600` permissions (`-rw-------`).

### Reporting a Vulnerability
If you discover a security vulnerability, please report it privately via **GitHub Security Advisories** rather than opening a public issue.
