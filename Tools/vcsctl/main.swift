import CVCSKit
import CSVNKit
import Foundation

// MARK: - 极简参数解析

struct Args {
    static let valueTakingKeys: Set<String> = [
        "m", "message",
        "user", "password",
        "trust-bundle",
        "revision", "r",
        "limit",
        "ca", "fetch-cert", "server",
    ]

    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                if i + 1 < argv.count {
                    positional.append(contentsOf: argv[(i + 1)...])
                }
                break
            } else if a.hasPrefix("-") && a.count > 1 {
                let rawKey = String(a.dropFirst(a.hasPrefix("--") ? 2 : 1))
                if let eqIdx = rawKey.firstIndex(of: "=") {
                    let key = String(rawKey[..<eqIdx])
                    let val = String(rawKey[rawKey.index(after: eqIdx)...])
                    flags[key] = val
                    i += 1
                } else if Self.valueTakingKeys.contains(rawKey) {
                    if i + 1 < argv.count {
                        flags[rawKey] = argv[i + 1]
                        i += 2
                    } else {
                        flags[rawKey] = ""
                        i += 1
                    }
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                    flags[rawKey] = argv[i + 1]
                    i += 2
                } else {
                    flags[rawKey] = "true"
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { flags[key] }
    func int(_ key: String) -> Int? { flags[key].flatMap(Int.init) }
    func bool(_ key: String) -> Bool { flags[key] != nil && flags[key] != "false" }
}

func parseArgs(_ argv: [String]) -> Args {
    Args(argv)
}

// MARK: - 输出

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误：\(message)\n").utf8))
    exit(1)
}

func requireURL(_ raw: String) -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
        die("非法的仓库 URL：\(raw)")
    }
    return url
}

func out(_ s: String) { print(s) }

func makeClient(_ args: Args, url: String? = nil, workingCopyPath: String? = nil) throws -> SVNClient {
    var user = args.string("user")
    var pass = args.string("password")

    // --ca <证书文件>：导入为受信任的内部 CA
    if let caPath = args.string("ca") {
        let data = try Data(contentsOf: URL(fileURLWithPath: caPath))
        let name = URL(fileURLWithPath: caPath).deletingPathExtension().lastPathComponent
        let fp = TrustStore.sha256Fingerprint(of: data)
        try TrustStore.shared.addCertificate(pem: data, name: name)
        print("已导入证书：\(name) (SHA-256: \(fp))")
    }
    // --fetch-cert <主机>：从服务器抓取并信任其证书（自签名场景）
    if let host = args.string("fetch-cert") {
        let probed = try TrustStore.shared.probeCertificate(host: host)
        try TrustStore.shared.addCertificate(pem: probed.pemData, name: host)
        print("已导入服务器证书：\(host) (SHA-256: \(probed.sha256Fingerprint))")
    }
    TrustStore.shared.install()

    var resolvedHost: String? = nil
    if let u = url, u.contains("://") {
        resolvedHost = URL(string: u)?.host
    }
    if resolvedHost == nil, let s = args.string("server") {
        resolvedHost = s
    }
    if resolvedHost == nil, let wc = workingCopyPath ?? (url?.contains("://") == false ? url : nil) {
        resolvedHost = SVNClient.workingCopyURL(at: URL(fileURLWithPath: wc))?.host
    }

    // 钥匙串 / 凭据库里存过就直接用（即使未显式传 --user 也自动匹配该主机的已存账号）
    if let h = resolvedHost {
        if user == nil {
            user = KeychainStore.listAccounts(server: h).first
        }
        if pass == nil, let u = user {
            if let p = KeychainStore.load(server: h, username: u) { pass = p }
        }
    }

    // --remember：把凭据存进 macOS 钥匙串与凭据库
    if args.bool("remember"), let h = resolvedHost, let u = user, let p = pass {
        try KeychainStore.save(username: u, password: p, server: h)
        var settings = AppSettingsStore.load()
        if let uStr = url, uStr.contains("://") {
            settings.repoURL = uStr.hasSuffix("/") ? String(uStr.dropLast()) : uStr
        }
        settings.username = u
        AppSettingsStore.save(settings)
        print("凭据已存入钥匙串：\(h) / \(u)")
    }

    let trustBundlePath = args.string("trust-bundle") ?? TrustStore.shared.caBundleURL.path
    return try SVNClient(
        username: user,
        password: pass,
        trustBundlePath: trustBundlePath
    )
}

// MARK: - 子命令

let rawArgs = Array(CommandLine.arguments.dropFirst())
guard let command = rawArgs.first else {
    out("""
    vcsctl — SwiftVCS 命令行工具

    用法:
      vcsctl info      <url>                          连接并显示仓库信息
      vcsctl ls        <url> [路径]                   浏览仓库目录
      vcsctl cat       <url> <路径>                   读取仓库文件内容
      vcsctl checkout  <url> <本地目录> [子路径]      检出
      vcsctl update    <工作副本目录>                同步到最新
      vcsctl status    <工作副本目录>                查看本地改动
      vcsctl add       <工作副本目录> [路径...]      将新文件纳入版本控制
      vcsctl diff      <工作副本目录> [路径...]      查看差异
      vcsctl commit    <工作副本目录> -m "说明"      提交
      vcsctl revert    <工作副本目录> [路径...]      回滚本地改动
      vcsctl log       <工作副本目录|URL> [路径]     查看提交日志
      vcsctl show      <仓库URL> <修订号> [路径]     查看某次修订的变更文件与差异

    通用选项:
      --user <用户名>  --password <口令>  --revision <修订号>  --limit <条数>
      --trust-bundle <证书包路径>
      --ca <证书文件>      导入并信任一张内部 CA 证书（PEM/DER）
      --fetch-cert <主机>  从服务器抓取证书并信任（自签名场景）
      --server <主机>      用于查找钥匙串中已保存的凭据
      --remember           把凭据存入 macOS 钥匙串（之后可免密连接）
    """)
    exit(0)
}

let args = parseArgs(Array(rawArgs.dropFirst()))

do {
    switch command {
    case "info":
        guard let urlString = args.positional.first else { die("需要仓库 URL") }
        let repoURL = requireURL(urlString)
        let client = try makeClient(args, url: urlString)
        let info = try await client.connect(to: repoURL, credentials: nil)
        out("仓库 URL : \(info.url)")
        if let root = info.rootURL {
            out("仓库根   : \(root)")
        }
        out("仓库 UUID: \(info.uuid ?? "-")")
        out("最新修订 : r\(info.youngestRevision)")

    case "ls":
        guard let urlString = args.positional.first else { die("需要仓库 URL") }
        let repoURL = requireURL(urlString)
        let client = try makeClient(args, url: urlString)
        _ = try await client.connect(to: repoURL, credentials: nil)
        let entries = try await client.browse(path: args.positional.count > 1 ? args.positional[1] : nil)
        out("修订  大小        类型  作者              路径")
        for e in entries.sorted(by: { $0.path < $1.path }) {
            let type = e.kind == .directory ? "d" : (e.kind == .symlink ? "l" : "-")
            let size = e.size.map { String($0) } ?? "-"
            let author = e.author ?? "-"
            let name = e.kind == .directory ? "\(e.path)/" : e.path
            out("r\(e.revision)  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(type)    \(author.padding(toLength: 16, withPad: " ", startingAt: 0))  \(name)")
        }

    case "cat":
        guard args.positional.count >= 2 else { die("需要 <url> <路径>") }
        let urlString = args.positional[0]
        let filePath = args.positional[1]
        let repoURL = requireURL(urlString)
        let client = try makeClient(args, url: urlString)
        _ = try await client.connect(to: repoURL, credentials: nil)
        let data = try await client.cat(path: filePath, revision: args.int("revision") ?? args.int("r"))
        FileHandle.standardOutput.write(data)

    case "checkout":
        guard args.positional.count >= 2 else { die("需要 <url> <本地目录> [子路径]") }
        let urlString = args.positional[0]
        let repoURL = requireURL(urlString)
        let client = try makeClient(args, url: urlString)
        let dest = URL(fileURLWithPath: args.positional[1])
        let subPath = args.positional.count > 2 ? args.positional[2] : nil
        _ = try await client.connect(to: repoURL, credentials: nil)
        let path = try await client.checkout(path: subPath, to: dest, revision: args.int("revision") ?? args.int("r"))
        out("已检出到 \(path.path)")

    case "update":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try makeClient(args, workingCopyPath: wc)
        let r = try await client.update(workingCopy: URL(fileURLWithPath: wc), revision: args.int("revision") ?? args.int("r"), progress: nil)
        out("已同步到 r\(r.revision)（更新 \(r.updatedCount)，新增 \(r.addedCount)，删除 \(r.deletedCount)）")
        if !r.conflicts.isEmpty {
            out("冲突：")
            for c in r.conflicts { out("  \(c)") }
        }

    case "status":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try makeClient(args, workingCopyPath: wc)
        let items = try await client.status(of: URL(fileURLWithPath: wc))
        let changed = items.filter { $0.kind.isPendingChange || $0.kind == .unversioned }
        if changed.isEmpty {
            out("工作副本干净，无本地改动（共扫描 \(items.count) 个条目）。")
        } else {
            out("状态  修订   路径")
            for s in changed.sorted(by: { $0.path < $1.path }) {
                out("\(s.kind.displayName.padding(toLength: 4, withPad: " ", startingAt: 0))  r\(s.baseRevision)  \(s.path)")
            }
        }
        if args.bool("all") {
            out("--- 全部条目 (\(items.count)) ---")
            for s in items.sorted(by: { $0.path < $1.path }) {
                out("[\(s.kind.displayName)] r\(s.baseRevision) \(s.path)")
            }
        }

    case "add":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let n = try await client.add(workingCopy: URL(fileURLWithPath: wc), paths: paths)
        out("已纳入版本控制 \(n) 个路径。")

    case "diff":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let diffs = try await client.diff(workingCopy: URL(fileURLWithPath: wc), paths: paths)
        if diffs.isEmpty { out("无差异。") }
        for d in diffs {
            out("=== \(d.path)  (+\(d.addedCount) -\(d.removedCount)) ===")
            if d.isBinary {
                out("[二进制文件] \(d.statusNotice ?? "无法显示文本差异")")
                continue
            }
            for h in d.hunks {
                out(h.header)
                for l in h.lines {
                    let mark: String
                    switch l.kind {
                    case .context: mark = " "
                    case .addition: mark = "+"
                    case .deletion: mark = "-"
                    }
                    out("\(mark)\(l.text)")
                }
            }
        }

    case "commit":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        guard let message = args.string("m") ?? args.string("message"), !message.isEmpty else { die("需要 -m \"提交说明\"") }
        let client = try makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let r = try await client.commit(workingCopy: URL(fileURLWithPath: wc), paths: paths, message: message, progress: nil)
        out("已提交 r\(r.revision)，共 \(r.committedCount) 个条目。")

    case "revert":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let n = try await client.revert(workingCopy: URL(fileURLWithPath: wc), paths: paths)
        out("已回滚 \(n) 个路径。")

    case "log":
        guard let target = args.positional.first else { die("需要工作副本目录或仓库 URL") }
        // 既支持工作副本路径，也支持直接给仓库 URL
        let client = try makeClient(args, url: target)
        let path = args.positional.count > 1 ? args.positional[1] : nil
        let url = target.contains("://") ? requireURL(target) : URL(fileURLWithPath: target)
        let entries = try await client.log(
            workingCopy: url,
            path: path,
            limit: args.int("limit") ?? 20,
            startRevision: args.int("revision") ?? args.int("r")
        )
        for e in entries {
            let date = ISO8601DateFormatter().string(from: e.date)
            let first = e.message
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? "（无提交说明）"
            out("r\(e.revision)  \(date)  \(e.author)")
            out("    \(first)")
            for c in e.changedPaths.prefix(6) { out("      · \(c)") }
        }

    case "show":
        guard let target = args.positional.first else {
            die("需要 <仓库URL|工作副本> <修订号> [路径]（或使用 -r <修订号>）")
        }
        let revRaw: String
        let pathFilter: String?
        if let optRev = args.string("revision") ?? args.string("r") {
            revRaw = optRev
            pathFilter = args.positional.count > 1 ? args.positional[1] : nil
        } else {
            guard args.positional.count >= 2 else {
                die("需要 <仓库URL|工作副本> <修订号> [路径]（或使用 -r <修订号>）")
            }
            revRaw = args.positional[1]
            pathFilter = args.positional.count > 2 ? args.positional[2] : nil
        }
        let cleanRevStr = (revRaw.hasPrefix("r") || revRaw.hasPrefix("R")) ? String(revRaw.dropFirst()) : revRaw
        guard let rev = Int(cleanRevStr), rev > 0 else {
            die("无效的修订号：\(revRaw)")
        }

        let client = try makeClient(args, url: target)
        let repoURL: URL
        if target.contains("://") {
            repoURL = requireURL(target)
        } else if let wcURL = SVNClient.workingCopyURL(at: URL(fileURLWithPath: target)) {
            repoURL = wcURL
        } else {
            die("无效的仓库 URL 或工作副本路径：\(target)")
        }

        let info = try await client.connect(to: repoURL, credentials: nil)
        let rootURL = info.rootURL ?? info.url
        let entries = try await client.log(
            workingCopy: rootURL,
            path: nil,
            limit: 1,
            startRevision: rev
        )
        if let entry = entries.first(where: { $0.revision == rev }) {
            let dateStr = ISO8601DateFormatter().string(from: entry.date)
            let msg = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
            out("r\(entry.revision) | \(entry.author) | \(dateStr)")
            out(msg.isEmpty ? "（无提交说明）" : msg)
            out("变更列表 (\(entry.changes.count)):")
            for c in entry.changes {
                let kindTag: String
                switch c.kind {
                case .file: kindTag = "f"
                case .directory: kindTag = "d"
                case .unknown: kindTag = "?"
                }
                if let cf = c.copyFromPath, let cfRev = c.copyFromRevision {
                    out("  \(c.action.rawValue) [\(kindTag)] \(c.path) (自 \(cf)@r\(cfRev))")
                } else {
                    out("  \(c.action.rawValue) [\(kindTag)] \(c.path)")
                }
            }
        }

        let diffs = try await client.diffRevision(rev, path: pathFilter)
        for d in diffs {
            out("=== \(d.path)  (+\(d.addedCount) -\(d.removedCount)) ===")
            if d.isBinary {
                out("[二进制文件] \(d.statusNotice ?? "无法显示文本差异")")
                continue
            }
            if let notice = d.statusNotice, d.hunks.isEmpty {
                out("[\(notice)]")
            }
            if d.isTruncated {
                out("[内容过大，已截断]")
            }
            for h in d.hunks {
                out(h.header)
                for l in h.lines {
                    let mark: String
                    switch l.kind {
                    case .context: mark = " "
                    case .addition: mark = "+"
                    case .deletion: mark = "-"
                    }
                    out("\(mark)\(l.text)")
                }
            }
        }

    default:
        die("未知命令「\(command)」，用 vcsctl 不带参数查看帮助")
    }
} catch let e as VCSError {
    die(e.errorDescription ?? "\(e)")
} catch {
    die("\(error)")
}
