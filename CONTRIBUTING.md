# Contributing to SwiftVCS / 贡献指南

Thank you for your interest in contributing to **SwiftVCS & VCS Explorer**!  
感谢您对 **SwiftVCS & VCS Explorer** 开源项目的关注与贡献！

---

## 简体中文指南

### 1. 开发环境准备
1. 确保运行在 **macOS 14.0 (Sonoma)** 或更高版本，已安装 Xcode Command Line Tools。
2. 安装构建期依赖：
   ```bash
   brew install subversion apr apr-util
   ```
3. 克隆仓库并验证构建与测试：
   ```bash
   swift build
   ./Tests/run_e2e.sh
   ```

### 2. 代码规范与约束
- **分层边界**：
  - `Sources/CVCSKit` 仅放置与具体版本控制系统无关的抽象协议和数据结构，不得引入 `CSVNShim` 或 AppKit/SwiftUI。
  - `Sources/CSVNShim` 中的 C 函数必须使用每调用独立的 `apr_pool_t *subpool` 并在返回前销毁，严禁在全局池上累积分配。
  - `Apps/VCSExplorer` 需兼容仅安装 `/Library/Developer/CommandLineTools` 的构建环境（避免依赖外部 Swift Macro 插件二进制，状态统一托管在 `@MainActor final class AppModel: ObservableObject` 或 `@AppStorage`）。
  - 展示修订号（`r8350`）、行号、统计数量时，请使用 `Text(verbatim:)` 或 `String(...)`，避免 SwiftUI `LocalizedStringKey` 自动插入千位分隔符逗号。
- **测试要求**：任何针对 `CSVNShim`、`CSVNKit` 或 `vcsctl` 的修改，均需保证 `./Tests/run_e2e.sh` 全部断言 100% 通过。
- **隐私与安全**：严禁在源码、注释、测试脚本或截图中提交任何真实企业内部 SVN 地址、账号、密码或私钥。

---

## English Guidelines

### 1. Development Setup
1. Requires **macOS 14.0 (Sonoma)** or later with Xcode Command Line Tools installed.
2. Install build-time libraries via Homebrew:
   ```bash
   brew install subversion apr apr-util
   ```
3. Build and run the offline end-to-end test suite:
   ```bash
   swift build
   ./Tests/run_e2e.sh
   ```

### 2. Coding Standards
- **Layer Separation**:
  - Keep `Sources/CVCSKit` free of SVN-specific or UI-specific dependencies.
  - Every C function in `Sources/CSVNShim/csvn.c` must allocate a per-call `apr_pool_t *subpool` and call `svn_pool_destroy(subpool)` before returning.
  - Ensure `Apps/VCSExplorer` compiles cleanly with standalone Command Line Tools (`swift build` without requiring full `Xcode.app` macro plugins).
  - Use `Text(verbatim:)` when rendering revision numbers (`r8350`) and line numbers so SwiftUI does not format integers with locale thousands separators.
- **Testing**: All pull requests must pass `./Tests/run_e2e.sh` with 0 failures.
- **Security**: Never commit real server URLs, credentials, or internal certificates.
