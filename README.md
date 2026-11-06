# SwiftVCS & VCS Explorer

<p align="center">
  <strong>Native macOS Subversion (SVN) Client & SDK built with Swift, SwiftUI, and C <code>libsvn</code></strong><br>
  <strong>基于 Swift、SwiftUI 与 C <code>libsvn</code> 构建的原生 macOS SVN 客户端与开发套件</strong>
</p>

<p align="center">
  <a href="#english-documentation">English</a> ·
  <a href="#简体中文文档">简体中文</a> ·
  <a href="./README_EN.md">README_EN.md</a> ·
  <a href="./README_ZH.md">README_ZH.md</a> ·
  <a href="./LICENSE">MIT License</a> ·
  <a href="./THIRD_PARTY_NOTICES.md">Third-Party Notices</a>
</p>

---

## 简体中文文档

**SwiftVCS** 是一套面向 macOS (Apple Silicon / Intel) 的原生 Subversion (SVN) 客户端与分层 SDK。不同于通过 `Process` 调起外部 `svn` 命令行并解析文本输出的传统包装器，SwiftVCS 通过精简的 C 桥接层（`CSVNShim`）直接调用 **Apache Subversion (`libsvn_client-1` / `libsvn_ra-1` / `libsvn_wc-1` / `libsvn_diff-1`)** 原生 C API，并在上层提供 **GitHub Desktop 风格的原生 SwiftUI 图形界面（`VCS Explorer`）** 与 **全功能命令行工具（`vcsctl`）**。

### 核心特性

1. **五层清晰架构（零外部 CLI 进程依赖）**
   - `CVCSKit`：与具体版本控制系统无关的 Swift 领域模型与 `RepositoryClient` 异步协议（修订、目录树、工作副本状态、结构化 `FileDiff`、并排配对行 `SplitDiffRow`）。
   - `CSVNShim`：基于 APR 内存池（Subpool per-call）与线程安全封装的 C11 桥接层，直接对接 `libsvn` 1.14+。
   - `CSVNKit`：Swift 并发安全（`SVNClient`）的 SVN 客户端实现、多编码智能解码器（UTF-8 / GB18030 / GBK / UTF-16）、自签名 TLS 证书信任库（`TrustStore`）与本地凭据库（`KeychainStore`）。
   - `vcsctl`：覆盖连接、浏览、读取、检出、同步、状态、纳管、差异、提交、回滚、日志及提交级比对（`show`）的命令行工具。
   - `VCSExplorer`：参考 **GitHub Desktop** 交互设计的 macOS 原生 SwiftUI 桌面端。

2. **GitHub Desktop 风格界面 (`VCS Explorer`)**
   - **三段式顶部工具栏 (`RepoToolbar`)**：当前仓库快速切换弹窗、当前浏览路径/工作副本弹窗、一键刷新/`SVN Update` 状态按钮及 TLS 证书信任状态徽章。
   - **三页签侧边导航 (`SidebarView`)**：
     - **历史 (`History` `⌘1`)**：支持按修订号（如 `r8350`）、作者、提交说明、涉及文件路径实时过滤；彩色作者首字母头像、相对时间显示、滚到底部自动分页加载更多历史。
     - **更改 (`Changes` `⌘2`)**：本地工作副本变更勾选列表（刷新时保留用户勾选状态）、一键纳管（`svn add`）、带二次确认的单文件还原（`svn revert`）、底部提交框（必填摘要 + 详细描述，`⌘↩` 提交勾选文件）。
     - **浏览 (`Browse` `⌘3`)**：远端仓库目录树面包屑导航、目录内实时过滤、在线代码行号预览（支持 UTF-8 与 GB18030 中文源码，自动跳过二进制大文件）及「查看此路径提交历史」联动跳转。

3. **提交级文件差异比对 (`Commit File Diff`) — 并排对比 & 统一视图**
   - 点击任意历史提交即可查看该修订涉及的全部变更文件（新增 `A`、修改 `M`、删除 `D`、替换 `R` 及 `copyfrom` 源路径提示）。
   - 支持 **并排对比 (`Split`，默认)** 与 **统一视图 (`Unified`)** 一键切换（快捷键 `⌘⇧D`），支持自动换行与横向滚动切换（内置中日韩双宽字符与 Tab 宽度估算）。
   - 底层基于 `svn_client_diff_peg7` 与 `svn_client_diff7`：
     - 修改文件（`M`）：直接对比 `r(N-1)` 与 `rN`，属性变更无文本差异时明确提示；
     - 拷贝/移动并修改（`A+` / `R+`）：自动跨路径对比 `copyfrom_path@copyfrom_rev` 与 `path@rN` 的真实增量；
     - 纯新增/纯删除（`A` / `D`）：自动拉取文本内容合成全绿新增或全红删除视图；
     - 二进制文件（`.jar`、`.png`、`.pdf` 等）：毫秒级识别并展示二进制信息卡片，绝不阻塞 UI，且在工作副本混合改动时按 `Index:` 分段解码，不会因二进制 `NUL` 字节截断后续文本文件差异。

4. **企业内网自签名 HTTPS 证书两步核验 (`Two-Step TLS Fingerprint Verification`)**
   - 针对使用内部私有 CA 或自签名证书的企业 SVN 服务器，提供「抓取并核验服务器证书 → 展示证书主体（Subject）与 `SHA-256` 指纹 → 用户确认无误后仅对该 HTTPS 主机和端口信任叶证书」的两步安全信任流，避免盲目信任（Blind TOFU）。

### 系统架构图

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Apps/VCSExplorer        GitHub Desktop 风格 SwiftUI 桌面端 (macOS 14+)│
│  Tools/vcsctl            全功能命令行工具                              │
├──────────────────────────────────────────────────────────────────────┤
│  Sources/CVCSKit         VCS 抽象协议 (RepositoryClient) 与公共数据模型 │
├──────────────────────────────────────────────────────────────────────┤
│  Sources/CSVNKit         SVNClient / 多编码 Diff 解析 / TrustStore    │
├──────────────────────────────────────────────────────────────────────┤
│  Sources/CSVNShim        libsvn C11 桥接 (csvn.h / csvn.c, APR 池管理) │
├──────────────────────────────────────────────────────────────────────┤
│  Apache Subversion       libsvn_client / ra / wc / diff / subr + APR │
└──────────────────────────────────────────────────────────────────────┘
```

### 快速开始与构建打包

#### 1. 环境要求
- **操作系统**：macOS 14.0 (Sonoma) 或更高版本（预编译包的最低版本取决于实际打包的动态库）
- **开发工具**：Xcode Command Line Tools（Swift 5.9+）
- **构建依赖**：通过 Homebrew 安装 `subversion` 与 `apr`（仅编译时需要；打包后的 `VCSExplorer.app` 已将全部依赖 `.dylib` 内置到 `Contents/Frameworks/`，目标机器无需安装 Homebrew）：

```bash
brew install subversion apr apr-util pkgconf
source scripts/svn_build_env.sh
```

#### 2. 编译与运行测试

```bash
# Debug 构建全部模块 (CVCSKit, CSVNKit, vcsctl, VCSExplorer)
swift build
swift run SwiftVCSChecks

# 运行 本地离线端到端测试套件（自动创建临时 file:// 仓库完成全链路验证）
./Tests/run_e2e.sh
```

#### 3. 打包独立可分发的应用包 (`VCSExplorer.app`)

```bash
./make_app.sh
```

执行 `./make_app.sh` 会自动：
1. 以 Release 模式编译 `VCSExplorer`；
2. 递归扫描并将 `libsvn_*`、`libapr*`、`libserf`、`libssl`、`libcrypto` 等 22 个非系统动态库拷入 `dist/VCSExplorer.app/Contents/Frameworks/`；
3. 将内置动态库加载路径重写为 `@rpath/<name>.dylib`，保留原始部署版本，并附带实际版本的许可证、NOTICE 和 gettext 源码；
4. 生成应用图标 `AppIcon.icns`、拷入空状态插画资源、执行 ad-hoc 代码签名与校验，最终输出：
   - `dist/VCSExplorer.app`
   - `dist/VCSExplorer-<架构>.zip`

默认产物使用 ad-hoc 签名，供本地测试。正式分发时用 `SWIFTVCS_SIGN_IDENTITY` 指定 Developer ID Application 身份，用 `SWIFTVCS_NOTARY_PROFILE` 指定已配置的公证凭据。

### 命令行工具 `vcsctl` 速查

```bash
# HTTPS 口令认证成功后可用 --remember 保存至 macOS 钥匙串
vcsctl info https://svn.example.com/repo --user alice --password '***' --remember

# 先查看指纹，再用管理员通过独立渠道提供的指纹确认
vcsctl info https://svn.example.com/repo --fetch-cert svn.example.com
vcsctl info https://svn.example.com/repo --fetch-cert svn.example.com --fingerprint '<经核验的 SHA-256 指纹>'

# 浏览远端目录与读取文件内容
vcsctl ls   https://svn.example.com/repo trunk/src
vcsctl cat  https://svn.example.com/repo trunk/src/main.swift --revision 42

# 查看某次历史提交的变更文件列表与 Unified Diff（支持位置参数或 -r）
vcsctl show https://svn.example.com/repo 42
vcsctl show https://svn.example.com/repo 42 trunk/src/main.swift

# 工作副本常用操作
vcsctl checkout https://svn.example.com/repo /path/to/wc
vcsctl status   /path/to/wc
vcsctl add      /path/to/wc src/new_file.swift
vcsctl diff     /path/to/wc
vcsctl commit   /path/to/wc -m "feat: add new_file.swift"
vcsctl revert   /path/to/wc src/new_file.swift
vcsctl update   /path/to/wc
vcsctl log      /path/to/wc --limit 50
```

---

## English Documentation

**SwiftVCS** is a native macOS Subversion (SVN) client and layered SDK written in Swift, SwiftUI, and C11. Instead of spawning `svn` child processes and scraping stdout, SwiftVCS links directly against **Apache Subversion (`libsvn_client-1`, `libsvn_ra-1`, `libsvn_wc-1`, `libsvn_diff-1`)** via a thread-safe C shim (`CSVNShim`) with per-operation APR subpool lifecycle management. It ships with both a **GitHub Desktop-inspired SwiftUI application (`VCS Explorer`)** and a **full-featured CLI (`vcsctl`)**.

### Key Highlights

1. **Five-Layer Native Architecture**
   - **`CVCSKit`**: VCS-agnostic Swift domain models and the async `RepositoryClient` protocol (`RepositoryInfo`, `RepositoryEntry`, `WorkingCopyStatus`, `LogEntry`, `ChangedPath`, `FileDiff`, `SplitDiffRow`).
   - **`CSVNShim`**: C11 bridge (`csvn.h` / `csvn.c`) wrapping `libsvn` with APR subpools, streaming output caps (`max_bytes`), and thread-local error propagation.
   - **`CSVNKit`**: Concurrency-safe `SVNClient`, multi-encoding text decoder (UTF-8, GB18030, GBK, UTF-16, ISO-8859-1), `TrustStore` for custom/self-signed TLS CAs, and `KeychainStore` (macOS Keychain, scoped to the HTTPS repository and authentication realm).
   - **`vcsctl`**: Command-line interface supporting `info`, `ls`, `cat`, `checkout`, `update`, `status`, `add`, `diff`, `commit`, `revert`, `log`, and commit-level `show`.
   - **`VCSExplorer`**: Native macOS SwiftUI desktop client modeled after **GitHub Desktop**.

2. **GitHub Desktop-Style UI (`VCS Explorer`)**
   - **Three-Segment Top Toolbar (`RepoToolbar`)**: Repository switcher popover, current browse path / working copy switcher popover, one-click Refresh / `SVN Update` status button, and TLS trust status badge.
   - **Three Sidebar Tabs (`SidebarView`)**:
     - **History (`⌘1`)**: Instant filtering by revision (`r8350`), author, commit message, or changed file path; deterministic author avatar badges; relative timestamps; infinite scroll pagination.
     - **Changes (`⌘2`)**: Working copy file checklist (preserving user selection across refreshes), one-click stage (`svn add`), confirmed discard (`svn revert`), and a GitHub Desktop commit box (`⌘↩` to commit checked paths).
     - **Browse (`⌘3`)**: Interactive breadcrumb bar, in-folder search filter, line-numbered remote file preview, and one-click "View Commit History for Path".

3. **Commit-Level File Diff (`Split` & `Unified` Views)**
   - Inspect every file changed in any revision (`A`, `M`, `D`, `R`, plus `copyfrom` provenance).
   - Toggle seamlessly between **Side-by-Side (`Split`)** and **Unified** diff modes (`⌘⇧D`), with soft-wrap or horizontal scroll (aware of CJK double-width glyphs and tab stops).
   - Powered by `svn_client_diff_peg7` and `svn_client_diff7`: accurately diffs copied/moved files against their `copyfrom` source, synthesizes full-file additions/deletions when appropriate, skips binary files (`.jar`, `.png`, `.pdf`, etc.) without blocking the UI, and decodes multi-file working copy diffs section-by-section so binary `NUL` bytes never truncate subsequent text file diffs.

4. **Two-Step TLS Certificate Fingerprint Verification**
   - For enterprise SVN servers using self-signed certificates or private CAs, `VCS Explorer` probes the server certificate first, displays its Subject and `SHA-256` fingerprint, and only trusts that leaf certificate for its HTTPS host and port after confirmation.

### Build, Test & Standalone Packaging

```bash
# 1. Install build-time dependencies via Homebrew (Apple Silicon or Intel)
brew install subversion apr apr-util pkgconf
source scripts/svn_build_env.sh

# 2. Build all targets
swift build
swift run SwiftVCSChecks

# 3. Run the offline E2E test suite (uses local file:// repositories)
./Tests/run_e2e.sh

# 4. Package a standalone, self-contained macOS app bundle
./make_app.sh
# Outputs:
#   dist/VCSExplorer.app (bundles all 22 libsvn/libapr/libserf dylibs under Contents/Frameworks/ via @rpath)
#   dist/VCSExplorer-<arch>.zip
```

---

To consume `CSVNKit` from another Swift package, install the Homebrew dependencies and source `scripts/svn_build_env.sh` from a SwiftVCS checkout before building the consumer. SwiftPM uses the exported `PKG_CONFIG_PATH` to find the native libraries.

## 工作副本协作 / Working copy collaboration

在「更改」页开启「含正常项」，右键已纳管文件即可删除、改名、移动或保留历史复制。更新后的文本冲突可采用当前文件、基线、传入版本或冲突前本地版本。工作副本菜单支持同仓库的指定修订合并，先预演再应用。文件操作和合并结果由用户审核后提交。

In Changes, enable normal entries to access delete, rename, move and history-preserving copy. Resolve text conflicts from the file menu. Preview and apply a same-repository revision merge from the working copy menu, then review and commit its files and merge metadata.

```bash
vcsctl rename /path/to/wc src/old.swift new.swift
vcsctl copy /path/to/wc src/new.swift src/example.swift
vcsctl resolve /path/to/wc src/example.swift --strategy current
vcsctl merge /path/to/wc --source https://svn.example.com/repo/branches/feature --revision 42 --dry-run
```

[界面与 CLI 集成 / GUI and CLI integration](docs/FRONTEND_INTEGRATION.md)

## 开源协议与第三方声明 / License & Third-Party Notices

- **SwiftVCS 源码协议 / Source License**：本项目源代码采用 **[MIT License](./LICENSE)** 开源。
- **第三方开源组件声明 / Third-Party Notices**：预编译或通过 `./make_app.sh` 打包生成的 `VCSExplorer.app` 内置了 Apache Subversion (`libsvn_*`)、Apache Portable Runtime (`libapr` / `libapr-util`)、Apache Serf (`libserf`)、OpenSSL (`libssl` / `libcrypto`)、LZ4 与 utf8proc 等动态库，其各自的开源许可证（Apache License 2.0、BSD License、MIT License 等）详见 **[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)**。
- **贡献指南与安全策略 / Contributing & Security**：请参阅 **[CONTRIBUTING.md](./CONTRIBUTING.md)** 与 **[SECURITY.md](./SECURITY.md)**。
