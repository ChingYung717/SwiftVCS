# SwiftVCS & VCS Explorer（简体中文详细文档）

<p align="left">
  <a href="./README.md">中英双语主文档 (README.md)</a> ·
  <a href="./README_EN.md">English Documentation (README_EN.md)</a> ·
  <a href="./LICENSE">MIT 开源协议</a> ·
  <a href="./THIRD_PARTY_NOTICES.md">第三方开源组件声明</a>
</p>

**SwiftVCS** 是面向 macOS 的原生 Subversion (SVN) 客户端与分层开发套件。它通过 C11 桥接层（`CSVNShim`）直接调用 `libsvn_client` 等原生 C 接口，提供 **GitHub Desktop 风格的图形界面（`VCS Explorer`）** 与 **命令行工具（`vcsctl`）**。

---

## 1. 模块划分与工程结构

```text
SwiftVCS/
├── Package.swift                 # SwiftPM 包配置（支持 macOS 14+，自动探测 /opt/homebrew 与 /usr/local）
├── Sources/
│   ├── CVCSKit/                  # 与具体 VCS 无关的公共协议 (RepositoryClient) 与值类型模型
│   ├── CSVNShim/                 # libsvn 1.14+ C11 封装层（APR 子内存池管理、流式限流、线程局部错误）
│   └── CSVNKit/                  # SVNClient 实现、多编码 Diff 解析器、TrustStore 与 KeychainStore
├── Tools/
│   └── vcsctl/                   # 命令行工具
├── Apps/
│   └── VCSExplorer/              # GitHub Desktop 风格 SwiftUI 桌面端（15 个源码文件 + 图标与插画资源）
├── Tests/
│   ├── CVCSKitTests/             # 单元测试目录
│   └── run_e2e.sh                # 42 项完全离线的端到端回归测试脚本（基于本地 file:// 仓库）
└── make_app.sh                   # 独立 .app 打包脚本（内置 22 个动态库至 Contents/Frameworks）
```

---

## 2. 界面快捷键一览 (`VCS Explorer`)

| 快捷键 | 功能说明 |
|---|---|
| `⌘1` | 切换到「历史 (History)」页签 |
| `⌘2` | 切换到「更改 (Changes)」页签 |
| `⌘3` | 切换到「浏览 (Browse)」页签 |
| `⌘R` | 刷新当前仓库日志、目录与工作副本状态 |
| `⌘O` | 选择并打开本地 SVN 工作副本目录 |
| `⌘⇧N` | 打开「连接 SVN 仓库与证书设置」弹窗 |
| `⌘⇧D` | 在「并排对比 (Split)」与「统一视图 (Unified)」之间切换代码比对模式 |
| `⌘↩` | 在「更改」页签提交已勾选的工作副本文件 |

---

## 3. 本地配置与安全设计

- **配置文件目录**：`~/.config/vcs-explorer/`（目录权限强制设为 `0700`）
  - `settings.json`：保存最近连接的仓库列表、工作副本路径与界面偏好。
  - `credentials.json`：当开启「记住凭据」时，以 `0600` 权限临时文件 + `replaceItemAt` 原子替换方式安全存储凭据。
  - `certs/*.crt` 与 `ca-bundle.crt`：保存经用户核对 `SHA-256` 指纹后导入的内部服务器证书，并与系统根证书合并供 `SSL_CERT_FILE` 使用。

---

## 4. 开源协议

本项目代码基于 **[MIT License](./LICENSE)** 开源；打包内置的第三方动态库（Apache Subversion、APR、Serf、OpenSSL 等）许可证声明详见 **[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)**。
