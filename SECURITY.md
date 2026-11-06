# Security Policy / 安全策略

## 凭据与 TLS

- 选择「记住 HTTPS 凭据」或使用 `vcsctl info --remember` 时，SwiftVCS 仅在 HTTPS 仓库连接和口令认证成功后，把密码和认证域存入 macOS 钥匙串。复用凭据时，协议、主机、端口、仓库路径、用户名和服务器认证域均须匹配。命令行复用时传入 `--user`。
- 从旧版升级后，请重新输入凭据。旧的 `credentials.json`、`certs/` 和 `ca-bundle.crt` 已停用。请在核对用途后自行清理旧文件。macOS 可能会在重新构建或从另一个可执行文件访问时要求授权钥匙串。
- 自签名 HTTPS 服务须先抓取叶证书，并使用管理员通过独立渠道提供的 SHA-256 指纹核验。GUI 由用户确认，CLI 通过 `--fetch-cert` 与 `--fingerprint` 精确匹配。信任只适用于核验过的主机和端口，证书有效期和主机名仍由 TLS 后端检查。
- 如需使用内部 CA，可传 `--ca /path/to/ca.pem` 给当前 SVN 会话，或按 Subversion 文档在 `~/.subversion/servers` 中配置。

## Credentials and TLS

- Remembering a password stores it and its authentication realm in the macOS Keychain after successful HTTPS password authentication. Reuse requires the same scheme, host, port, repository path, user, and authentication realm. CLI users specify the user with `--user`.
- After upgrading, enter credentials again and verify any previously trusted certificates. The old `credentials.json`, `certs/`, and `ca-bundle.crt` are no longer used. macOS may ask for Keychain approval when using a rebuilt app or a different executable.
- For self-signed HTTPS servers, compare the leaf certificate's SHA-256 fingerprint with a value from your administrator through a separate channel. Confirm it in the GUI or pass the expected value with `--fetch-cert` and `--fingerprint` in the CLI. The exception applies to the verified host and port. TLS hostname and validity checks still apply.
- Use `--ca /path/to/ca.pem` to supply a private CA for the current SVN client context, or configure it in `~/.subversion/servers`.

请通过 GitHub 仓库的私密漏洞报告渠道提交安全问题。/ Please report vulnerabilities through GitHub's private vulnerability reporting channel.
