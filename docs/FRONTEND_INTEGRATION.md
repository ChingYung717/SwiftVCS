# VCS Explorer 界面集成

本次变更涉及 SwiftUI 与本地 SVN 后端。界面通过 `AppModel` 访问 libsvn。

| 界面操作 | 调用与参数 | 结果与错误 |
|---|---|---|
| 修改连接地址或用户名 | 写入 `repoURLString` 或 `username` | 清除密码输入。更换地址也会清除待确认的证书。 |
| 连接仓库 | `connect(dismissSheetOnSuccess:)` 使用 URL、用户名、密码和「记住 HTTPS 凭据」状态 | 成功后返回仓库信息并加载目录和历史。连接期间修改地址或凭据时提示重新连接。钥匙串访问失败会显示系统错误。 |
| 抓取 HTTPS 证书 | `probeServerCertificate()` 从当前 URL 取得主机和端口 | 展示叶证书主体和 SHA-256 指纹。抓取期间切换地址时丢弃旧结果。 |
| 确认证书 | 独立核对指纹后调用 `confirmPendingCertificateAndConnect(dismissOnSuccess:)` | 验证证书属于当前端点后保存并重试连接。TLS 仍检查证书有效期和主机名。 |
| 提交改动 | `commitCheckedChanges()` 传入勾选路径和提交说明 | 有新修订时显示修订号。空提交显示没有可提交的改动。 |

升级后需要重新输入 HTTPS 凭据，并为原来使用自签名证书的端点重新核验叶证书。
