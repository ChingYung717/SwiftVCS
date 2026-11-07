# Security Policy / 安全策略

## 凭据、本地设置与 TLS 边界 (Credentials, Local Settings & TLS Boundaries)

### 1. 凭据存储与 URL 清洗 (SV-01, SV-12, SV-13)
- **macOS 钥匙串隔离存储**：选择「记住 HTTPS 凭据」或使用 `vcsctl info --remember` 时，SwiftVCS 仅在 HTTPS 仓库连接与口令认证成功后，将口令及服务器认证域（Realm）存入 macOS 钥匙串（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。后续复用时，协议（`https`）、主机、端口、仓库路径、用户名和认证域（Realm）均须精确匹配。
- **`settings.json` 绝不持久化口令**：客户端配置文件 `~/.config/vcs-explorer/settings.json` 写入前均经过 `SVNURLSanitizer.sanitizeForPersistence` 清洗：
  - 剥离所有协议中的内嵌口令（`password`）；
  - 剥离 `https://`、`http://`、`svn://`、`file://` 中的内嵌用户名（`user`）；
  - 保留 `svn+ssh://user@host/path` 中合法的 SSH 目标用户名，同时剥离可能误填的口令；
  - 对无法解析或 authority 含多重未编码 `@` 的疑似凭据输入直接拒绝落盘；
  - 启动加载旧版 `settings.json` 时，若 `repoURL` 或 `recentRepos` 含历史内嵌凭据，会立即在内存中清洗、去重并以 `0700`（目录）/ `0600`（文件）权限原子覆写回磁盘。
- **命令行安全输入与诊断脱敏**：
  - `vcsctl` 推荐使用 `--password-stdin` 从标准输入读取口令，避免通过 `--password <口令>` 暴露在进程列表（`ps`）或 Shell 历史中；
  - C 桥接层（`CSVNShim`）使用 `memset_s` 在上下文销毁及每次认证回调临时池清理时擦除可控的 C 口令缓冲区（注意：Swift `String` 运行时及 `libsvn`/`APR` 内部产生的历史副本不受此保证约束）；
  - 错误链格式化（`csvn_set_error`）与 Swift 错误展示均通过内存流及正则脱敏，不创建 `/tmp` 临时错误文件，也不在 UI、剪贴板或终端标准错误回显 URL 内嵌口令。
- **旧版升级与历史备份清理提示**：
  - 旧版 `credentials.json`、`certs/`、`ca-bundle.crt` 已停用；
  - 若升级前曾在旧版 URL 输入框填入过形如 `https://user:pass@host/repo` 的内嵌口令，启动新版后当前 `~/.config/vcs-explorer/settings.json` 会被自动清洗重写，但请自行检查并清理 Time Machine 备份、终端历史记录（`~/.zsh_history`）或手工拷贝过的旧配置文件，并在必要时轮换对应 SVN 账号口令。

### 2. TLS 证书信任模式说明 (SV-02, SV-03)
- **当前模式：按 `host:port` 绑定的叶证书信任例外（非严格证书固定 / Non-Strict Certificate Pinning）**：
  - 针对使用自签名证书或内部未知私有 CA 的企业 HTTPS SVN 服务器，SwiftVCS 提供「先抓取服务器叶证书 → 用户核对管理员通过独立渠道提供的 `SHA-256` 指纹 → 确认后保存到 `~/.config/vcs-explorer/pinned-certs/<host>:<port>.crt`」的两步核验流程（CLI 对应 `vcsctl info <url> --fetch-cert <host> --fingerprint <sha256>`）。
  - **重要边界**：由于 Subversion (`libsvn_ra_serf`) 仅在默认系统 CA 或显式配置的 CA 链校验失败（`SVN_AUTH_SSL_UNKNOWNCA`）时才触发 `svn_auth_ssl_server_trust_prompt_func_t` 回调，该机制本质上是**针对自签名/未知 CA 的 `host:port` 叶证书信任例外**，而**不是**能拦截任意公共受信任 CA 签发替代证书的严格公钥/叶证书固定（Strict Pinning）。
  - **主机名与有效期强制校验**：即使叶证书 `SHA-256` 指纹已导入信任库，`CSVNShim` 仅放行 `SVN_AUTH_SSL_UNKNOWNCA`，**绝不放行**主机名不匹配（`SVN_AUTH_SSL_CNMISMATCH`）、证书已过期（`SVN_AUTH_SSL_EXPIRED`）或尚未生效（`SVN_AUTH_SSL_NOTYETVALID`）。若服务器证书缺少与连接地址匹配的 SAN/CN，请在服务端重新签发包含正确 SAN 的证书。
- **使用私有 CA 根证书**：可通过 `vcsctl --ca /path/to/ca.pem` 或 `--trust-bundle /path/to/ca-bundle.pem` 为当前 SVN 会话显式指定受信任的 CA 证书包。
- **严格固定模式（SV-03 规划说明）**：若未来需要「即使服务端出示由系统默认 CA 签发的其他合法证书也必须拒绝」的严格 Pinning 模式，需单独引入显式隔离的 Subversion 配置与会话层策略，当前版本不作此宣称。

---

## English Summary

### 1. Credential Handling & Settings Sanitization (SV-01, SV-12, SV-13)
- **macOS Keychain**: Passwords are stored in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) only after a successful HTTPS password authentication, scoped to scheme, host, port, repository path, username, and authentication realm.
- **No Passwords in `settings.json`**: `SVNURLSanitizer.sanitizeForPersistence` strips embedded passwords from all URLs and strips embedded usernames from `https://`, `http://`, `svn://`, and `file://` URLs while preserving `user@` only for `svn+ssh://`. Malformed URLs with multiple `@` characters in the authority are rejected. Legacy `settings.json` files containing embedded credentials in `repoURL` or `recentRepos` are automatically sanitized, deduplicated, and atomically rewritten with `0700` directory / `0600` file permissions upon load.
- **CLI & Memory Hygiene**: Prefer `vcsctl --password-stdin` over `--password`. Controllable C password buffers are zeroed with `memset_s` on cleanup (note that Swift `String` and internal `libsvn`/APR allocations cannot be guaranteed zeroed). Error messages redact embedded URL credentials in memory without creating `/tmp` files.
- **Post-Upgrade Cleanup**: If you previously entered `https://user:pass@host/repo` in an older build, verify and clean any external backups or shell histories and rotate affected passwords if needed.

### 2. TLS Trust Model (SV-02, SV-03)
- **Host:Port Self-Signed / Unknown-CA Certificate Exception (Not Strict Pinning)**:
  - Importing a leaf certificate after verifying its `SHA-256` fingerprint in the GUI or via `vcsctl info --fetch-cert <host> --fingerprint <sha256>` grants a trust exception for `SVN_AUTH_SSL_UNKNOWNCA` on that exact `host:port` when the server certificate matches the saved leaf certificate.
  - Because `libsvn_ra_serf` only invokes the server-trust callback when normal CA validation fails, this mode is a **self-signed / unknown-CA trust exception**, not strict certificate pinning against certificates issued by trusted CAs.
  - **Strict Hostname & Validity Enforcement**: `SVN_AUTH_SSL_CNMISMATCH`, `SVN_AUTH_SSL_EXPIRED`, and `SVN_AUTH_SSL_NOTYETVALID` are never bypassed, even when the leaf certificate fingerprint matches.
- **Private CA Bundles**: Pass `--ca /path/to/ca.pem` or `--trust-bundle /path/to/ca-bundle.pem` to validate against a custom CA bundle.

---

## 仓库安全基线与维护者核查清单 (Repository Security Checklist · SV-06 / SV-07 / SV-08 / SV-09)

仓库管理员在 GitHub 远端维护时，可通过以下命令核查并开启仓库级安全设置（SV-06）：

```bash
# 1. 开启私密漏洞报告 (Private Vulnerability Reporting) 与 Dependabot 告警/自动安全更新
gh api -X PUT repos/ChingYung717/SwiftVCS/private-vulnerability-reporting
gh api -X PUT repos/ChingYung717/SwiftVCS/vulnerability-alerts
gh api -X PUT repos/ChingYung717/SwiftVCS/automated-security-fixes

# 2. 开启 Secret Scanning 与 Push Protection
gh api -X PATCH repos/ChingYung717/SwiftVCS \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

# 3. 为 main 分支绑定必过 CI 检查 ("Build, Test & Package (macOS arm64)") 并禁止强推/删除
gh api -X PUT repos/ChingYung717/SwiftVCS/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build, Test & Package (macOS arm64)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

请通过 GitHub 仓库的私密漏洞报告渠道提交安全问题。/ Please report vulnerabilities through GitHub's private vulnerability reporting channel.
