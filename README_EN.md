# SwiftVCS & VCS Explorer (English Documentation)

<p align="left">
  <a href="./README.md">Bilingual Main README</a> ·
  <a href="./README_ZH.md">简体中文文档 (README_ZH.md)</a> ·
  <a href="./LICENSE">MIT License</a> ·
  <a href="./THIRD_PARTY_NOTICES.md">Third-Party Notices</a>
</p>

**SwiftVCS** is a native macOS Subversion (SVN) client and layered SDK built with Swift, SwiftUI, and C11. Rather than invoking external `svn` CLI processes and parsing text output, SwiftVCS bridges directly to **Apache Subversion (`libsvn_client-1`, `libsvn_ra-1`, `libsvn_wc-1`, `libsvn_diff-1`)** through a thread-safe C shim (`CSVNShim`) and provides both a **GitHub Desktop-inspired macOS app (`VCS Explorer`)** and a **command-line tool (`vcsctl`)**.

---

## 1. Architecture

```text
SwiftVCS/
├── Package.swift                 # SwiftPM manifest (macOS 14+, uses pkg-config)
├── Sources/
│   ├── CVCSKit/                  # VCS-agnostic domain types & async RepositoryClient protocol
│   ├── CSVNShim/                 # C11 bridge over libsvn_client / ra / wc / diff with APR subpools
│   └── CSVNKit/                  # SVNClient, multi-encoding diff parser, TrustStore & KeychainStore
├── Tools/
│   └── vcsctl/                   # Full-featured CLI client
├── Apps/
│   └── VCSExplorer/              # GitHub Desktop-style SwiftUI macOS application (15 view/model files)
├── Tests/
│   ├── CVCSKitTests/             # Unit test target
│   └── run_e2e.sh                # offline end-to-end test suite (file:// repository)
└── make_app.sh                   # Standalone .app bundler (rewrites 22 dylibs into Contents/Frameworks)
```

---

## 2. Features

| Capability | Underlying `libsvn` API | Description |
|---|---|---|
| **1. Connect & Inspect** | `svn_client_uuid_from_url`, `svn_ra_get_latest_revnum`, `svn_ra_get_repos_root2` | Connects to remote repositories or subdirectories, resolves repository root URL, UUID, and HEAD revision. |
| **2. Remote Browse (`ls` & `cat`)** | `svn_client_ls3`, `svn_client_cat2` | Lists remote directories with author/revision/size metadata and previews remote files with UTF-8 / GB18030 auto-detection. |
| **3. Checkout** | `svn_client_checkout3` | Checks out full repositories or subdirectories at HEAD or a specific peg revision. |
| **4. Update** | `svn_client_update4` | Updates working copies to the latest revision. |
| **5. Working Copy Status & Stage** | `svn_client_status6`, `svn_client_add5` | Scans modified, added, deleted, conflicted, and unversioned files; stages unversioned paths. |
| **6. Working Copy Diff** | `svn_client_diff6` | Parses multi-file unified diffs without truncating on binary `NUL` bytes. |
| **7. Commit** | `svn_client_commit6` | Commits selected paths with summary and description. |
| **8. Revert** | `svn_client_revert4` | Reverts local modifications on files or directories. |
| **9. Commit History (`log`)** | `svn_client_log5` | Streams commit logs with changed paths, node kinds (`file`/`dir`), and `copyfrom` metadata; supports pagination. |
| **10. Commit-Level File Diff** | `svn_client_diff_peg7`, `svn_client_diff7` | Computes per-file diffs for any historical commit (`M`, `A`, `D`, `R`, `A+` copy+modify) in **Split (Side-by-Side)** or **Unified** view. |

---

## 3. Building & Packaging

### Prerequisites
- macOS 14.0 (Sonoma) or later (Apple Silicon `arm64` or Intel `x86_64`)
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew `subversion` and `apr` (required on the build machine only):

```bash
brew install subversion apr apr-util pkgconf
```

### Build & Run Tests

```bash
./scripts/svn_build_env.sh
source scripts/svn_build_env.sh
swift run SwiftVCSChecks
./Tests/run_e2e.sh
```

### Build Standalone `VCSExplorer.app`

```bash
./make_app.sh
```

`make_app.sh` builds the Release executable, copies all required `libsvn_*`, `libapr*`, `libserf`, and `libssl` dynamic libraries into `dist/VCSExplorer.app/Contents/Frameworks/`, rewrites load paths to `@rpath`, preserves each library’s deployment target, includes the licenses and gettext source, and produces `dist/VCSExplorer-<arch>.zip`. The default ad-hoc signature is for local testing. For distribution, set `SWIFTVCS_SIGN_IDENTITY` and `SWIFTVCS_NOTARY_PROFILE` to use Developer ID and notarization.

---

## 4. License

SwiftVCS is released under the **[MIT License](./LICENSE)**. See **[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)** for licenses of bundled third-party libraries (Apache Subversion, APR, Serf, OpenSSL, LZ4, utf8proc).

## Working copy collaboration

Enable normal entries in Changes to delete, rename, move, or copy versioned files with history. Text conflicts support current, base, incoming and local resolution. Use the working copy menu to preview and apply a same-repository single revision or forward range. Review both file changes and `svn:mergeinfo` before committing.

[GUI and CLI integration](docs/FRONTEND_INTEGRATION.md)
