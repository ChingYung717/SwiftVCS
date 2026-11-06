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
        "limit", "source", "from", "to", "peg", "strategy",
        "ca", "fetch-cert", "fingerprint", "server", "file", "path",
    ]

    var positional: [String] = []
    var flags: [String: String] = [:]
    var duplicates: Set<String> = []

    private mutating func setFlag(_ key: String, _ value: String) {
        if flags.updateValue(value, forKey: key) != nil { duplicates.insert(key) }
    }

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
                    setFlag(key, val)
                    i += 1
                } else if Self.valueTakingKeys.contains(rawKey) {
                    if i + 1 < argv.count {
                        setFlag(rawKey, argv[i + 1])
                        i += 2
                    } else {
                        setFlag(rawKey, "")
                        i += 1
                    }
                } else if ["dry-run", "exact", "raw", "inherited", "parents"].contains(rawKey) {
                    setFlag(rawKey, "true")
                    i += 1
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                    setFlag(rawKey, argv[i + 1])
                    i += 2
                } else {
                    setFlag(rawKey, "true")
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

func printPropertyChanges(_ changes: [PropertyChange]) {
    guard !changes.isEmpty else { return }
    out("SVN 属性变更")
    func value(_ data: Data?) -> String {
        guard let data else { return "（不存在）" }
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return String(reflecting: text)
        }
        return "二进制（\(data.count) 字节）"
    }
    for change in changes {
        out("  \(change.name)")
        out("  − \(value(change.oldValue))")
        out("  + \(value(change.newValue))")
    }
}

func requireURL(_ raw: String) -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), (url.isFileURL && url.user == nil && url.password == nil) || SVNOrigin(url) != nil else {
        die("非法的仓库 URL，请通过独立选项传递认证凭据")
    }
    return url
}

func out(_ s: String) { print(s) }

func makeClient(_ args: Args, url: String? = nil, workingCopyPath: String? = nil,
                rememberBeforeOperation: Bool = true) async throws -> SVNClient {
    let repository: URL?
    if let url, url.contains("://") {
        repository = requireURL(url)
    } else if let wc = workingCopyPath ?? url {
        repository = SVNClient.workingCopyURL(at: URL(fileURLWithPath: wc))
    } else {
        repository = nil
    }

    if let host = args.string("server"), repository.flatMap(SVNOrigin.init)?.host != host.lowercased() {
        throw VCSError.invalidArgument("--server 必须与实际仓库的主机一致")
    }

    let client = try SVNClient(
        username: args.string("user"),
        password: args.string("password"),
        trustBundlePath: args.string("trust-bundle") ?? args.string("ca"),
        baseURL: repository
    )
    if rememberBeforeOperation && args.bool("remember") {
        guard let repository, SVNOrigin(repository)?.scheme == "https" else {
            throw VCSError.invalidArgument("仅支持保存 HTTPS 仓库的凭据")
        }
        _ = try await client.connect(to: repository, credentials: nil)
        try await rememberCredentials(client)
    }
    return client
}

func rememberCredentials(_ client: SVNClient) async throws {
    guard try await client.rememberPassword() else {
        throw VCSError.invalidArgument("仅在成功完成 HTTPS 口令认证后才能保存凭据")
    }
    out("凭据已存入 macOS 钥匙串")
}

// 属性值原样输出时，不经过 Swift 字符串或 print。
func nodeCommand(_ command: String, _ args: Args) async throws {
    let read = command == "proplist" || command == "propget"
    let common: Set<String> = ["user", "password", "trust-bundle", "ca", "server"]
    let specific: Set<String>
    switch command {
    case "proplist": specific = ["path", "revision", "peg", "inherited"]
    case "propget": specific = ["path", "revision", "peg", "raw"]
    case "propset": specific = ["path", "file"]
    case "propdel", "ignore": specific = ["path"]
    default: specific = ["parents"]
    }
    let invalid = VCSError.invalidArgument("参数不正确，请查看 vcsctl 命令帮助")
    guard let input = args.positional.first, !input.isEmpty,
          args.duplicates.isEmpty, Set(args.flags.keys).isSubset(of: common.union(specific)),
          args.flags.values.allSatisfy({ !$0.isEmpty }) else { throw invalid }
    for flag in ["inherited", "raw", "parents"] {
        if let value = args.string(flag), value != "true" && value != "false" { throw invalid }
    }
    for flag in ["revision", "peg"] where args.string(flag) != nil {
        guard let n = args.int(flag), n >= 0, n <= Int(Int32.max) else { throw invalid }
    }
    let count = args.positional.count
    let file = args.string("file")
    switch command {
    case "proplist", "ignore": guard count == 1 else { throw invalid }
    case "propset": guard count == (file == nil ? 3 : 2) else { throw invalid }
    default: guard count == 2 else { throw invalid }
    }
    let root = URL(fileURLWithPath: input)
    let path = args.string("path") ?? "."
    let isURL = input.contains("://")
    guard !isURL || (read && args.string("path") == nil) else {
        throw VCSError.invalidArgument("仓库 URL 只接受完整 URL 的属性查询；写入须指定本地工作副本")
    }
    let target: PropertyTarget = isURL ? .repository(requireURL(input)) : .workingCopy(root: root, path: path)
    let client = try await makeClient(args, url: isURL ? input : nil, workingCopyPath: isURL ? nil : input)
    let name = count >= 2 ? args.positional[1] : ""
    let rev = args.int("revision")
    let peg = args.int("peg")

    switch command {
    case "proplist":
        for property in try await client.properties(at: target, revision: rev, peg: peg, inherited: args.bool("inherited")) {
            out("\(property.name)\t\(property.source ?? "直接设置")")
        }
    case "propget":
        guard let value = try await client.property(name, at: target, revision: rev, peg: peg) else {
            throw VCSError.invalidArgument("目标未设置属性「\(name)」")
        }
        if args.bool("raw") {
            try FileHandle.standardOutput.write(contentsOf: value)
        } else {
            let property = NodeProperty(target: target, source: nil, name: name, value: value)
            out(property.textValue ?? "[二进制属性，\(value.count) 字节；用 --raw 读取]")
        }
    case "propset", "propdel":
        let value: Data?
        if command == "propdel" {
            value = nil
        } else if let file {
            value = try Data(contentsOf: URL(fileURLWithPath: file))
        } else {
            value = Data(args.positional[2].utf8)
        }
        try await client.setProperty(name, value: value, workingCopy: root, path: path)
        out("已在工作副本\(value == nil ? "删除" : "设置")属性「\(name)」，待提交")
    case "ignore":
        let rules = try await client.ignoreRules(workingCopy: root, directory: path)
        out("配置默认规则：")
        rules.defaults.forEach(out)
        out("目录 svn:ignore：")
        if let local = rules.directoryRules { out(local.textValue ?? "[二进制属性]") }
        out("svn:global-ignores（含继承）：")
        for rule in rules.globalRules {
            out("\(rule.source ?? path)：\(rule.textValue ?? "[二进制属性]")")
        }
    case "mkdir":
        let paths = try await client.makeDirectory(workingCopy: root, path: name,
                                                   parents: args.bool("parents"), expectedCount: nil)
        out("已在工作副本新建目录，待提交：\(paths.joined(separator: ", "))")
    default:
        throw invalid
    }
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
      vcsctl delete    <工作副本> <路径> [路径...]    标记删除，待提交
      vcsctl move      <工作副本> <源> <目标>         移动文件，待提交
      vcsctl rename    <工作副本> <源> <新文件名>     同目录改名，待提交
      vcsctl copy      <工作副本> <源> <目标>         保留来源历史复制，待提交
      vcsctl resolve   <工作副本> <路径> --strategy current|base|incoming|local
      vcsctl merge     <工作副本> --source <URL> --revision N [--peg N] [--dry-run]
      vcsctl merge     <工作副本> --source <URL> --from A --to B [--peg N] [--dry-run]
      vcsctl proplist  <工作副本|URL> [--path 相对路径] [--inherited] [--revision N] [--peg N]
      vcsctl propget   <工作副本|URL> <属性名> [--path 相对路径] [--raw] [--revision N] [--peg N]
      vcsctl propset   <工作副本> <属性名> <值> [--path 相对路径]
      vcsctl propset   <工作副本> <属性名> --file <本地文件> [--path 相对路径]
      vcsctl propdel   <工作副本> <属性名> [--path 相对路径]
      vcsctl ignore    <工作副本> [--path 相对目录]
      vcsctl mkdir     <工作副本> <相对路径> [--parents]
      commit --exact   仅提交明确列出的路径，目录只提交自身
      revert --exact   仅回滚明确列出的路径，目录只回滚自身

    通用选项:
      --user <用户名>  --password <口令>  --revision <修订号>  --limit <条数>
      --trust-bundle <证书包路径>
      --ca <PEM 文件>             仅在当前 SVN 会话使用的 CA 证书包
      info --fetch-cert <主机>     显示服务器叶证书的 SHA-256 指纹
      info --fingerprint <指纹>    与独立获得的指纹匹配后信任证书
      --remember                 成功认证后保存到 macOS 钥匙串，复用时传 --user
    """)
    exit(0)
}

let args = parseArgs(Array(rawArgs.dropFirst()))

do {
    for key in ["revision", "r", "limit", "from", "to", "peg"] where args.string(key) != nil {
        guard let value = args.int(key), (0...Int(Int32.max)).contains(value) else {
            throw VCSError.invalidArgument("--\(key) 需要 0...\(Int32.max) 范围内的整数")
        }
    }
    if command != "info" &&
        (args.string("fetch-cert") != nil || args.string("fingerprint") != nil) {
        throw VCSError.invalidArgument("--fetch-cert 和 --fingerprint 请用于 info")
    }
    switch command {
    case "info":
        guard let urlString = args.positional.first else { die("需要仓库 URL") }
        let repoURL = requireURL(urlString)
        if let host = args.string("fetch-cert") {
            guard let origin = SVNOrigin(repoURL), origin.scheme == "https", origin.host == host.lowercased() else {
                throw VCSError.invalidArgument("--fetch-cert 必须匹配 HTTPS 仓库主机")
            }
            let probed = try TrustStore.shared.probeCertificate(host: origin.host, port: origin.port)
            out("SHA-256: \(probed.sha256Fingerprint)")
            guard let fingerprint = args.string("fingerprint") else { break }
            let normalized = fingerprint.replacingOccurrences(of: ":", with: "").uppercased()
            let actual = probed.sha256Fingerprint.replacingOccurrences(of: ":", with: "")
            guard normalized == actual else {
                throw VCSError.invalidArgument("SHA-256 指纹不匹配，证书未保存")
            }
            try TrustStore.shared.trust(probed, for: repoURL)
        } else if args.string("fingerprint") != nil {
            throw VCSError.invalidArgument("--fingerprint 需与 --fetch-cert 一起使用")
        }
        let client = try await makeClient(args, url: urlString, rememberBeforeOperation: false)
        let info = try await client.connect(to: repoURL, credentials: nil)
        if args.bool("remember") {
            try await rememberCredentials(client)
        }
        out("仓库 URL : \(info.url)")
        if let root = info.rootURL {
            out("仓库根   : \(root)")
        }
        out("仓库 UUID: \(info.uuid ?? "-")")
        out("最新修订 : r\(info.youngestRevision)")

    case "ls":
        guard let urlString = args.positional.first else { die("需要仓库 URL") }
        let repoURL = requireURL(urlString)
        let client = try await makeClient(args, url: urlString)
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
        let client = try await makeClient(args, url: urlString)
        _ = try await client.connect(to: repoURL, credentials: nil)
        let data = try await client.cat(path: filePath, revision: args.int("revision") ?? args.int("r"))
        FileHandle.standardOutput.write(data)

    case "checkout":
        guard args.positional.count >= 2 else { die("需要 <url> <本地目录> [子路径]") }
        let urlString = args.positional[0]
        let repoURL = requireURL(urlString)
        let client = try await makeClient(args, url: urlString)
        let dest = URL(fileURLWithPath: args.positional[1])
        let subPath = args.positional.count > 2 ? args.positional[2] : nil
        _ = try await client.connect(to: repoURL, credentials: nil)
        let path = try await client.checkout(path: subPath, to: dest, revision: args.int("revision") ?? args.int("r"))
        out("已检出到 \(path.path)")

    case "update":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try await makeClient(args, workingCopyPath: wc)
        let r = try await client.update(workingCopy: URL(fileURLWithPath: wc), revision: args.int("revision") ?? args.int("r"), progress: nil)
        out("已同步到 r\(r.revision)（更新 \(r.updatedCount)，新增 \(r.addedCount)，删除 \(r.deletedCount)）")
        if !r.conflicts.isEmpty {
            out("冲突：")
            for c in r.conflicts { out("  \(c)") }
        }

    case "status":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try await makeClient(args, workingCopyPath: wc)
        let items = try await client.status(of: URL(fileURLWithPath: wc))
        let changed = items.filter { $0.kind.isPendingChange || $0.kind == .unversioned }
        if changed.isEmpty {
            out("工作副本干净，无本地改动（共扫描 \(items.count) 个条目）。")
        } else {
            out("状态  修订   路径")
            for s in changed.sorted(by: { $0.path < $1.path }) {
                let details = s.conflictKinds.map(\.displayName).sorted().joined(separator: "、")
                let conflict = details.isEmpty ? "" : " [\(details)冲突]"
                let moved = s.movedTo.map { " → \($0)" } ?? s.movedFrom.map { " ← \($0)" } ?? ""
                let mergeInfo = s.mergeInfoChanged ? " [svn:mergeinfo]" : ""
                out("\(s.kind.displayName.padding(toLength: 4, withPad: " ", startingAt: 0))  r\(s.baseRevision)  \(s.path)\(moved)\(conflict)\(mergeInfo)")
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
        let client = try await makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let n = try await client.add(workingCopy: URL(fileURLWithPath: wc), paths: paths)
        out("已纳入版本控制 \(n) 个路径。")

    case "diff":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try await makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let diffs = try await client.diff(workingCopy: URL(fileURLWithPath: wc), paths: paths)
        if diffs.isEmpty { out("无差异。") }
        for d in diffs {
            out("=== \(d.path)  (+\(d.addedCount) -\(d.removedCount)) ===")
            printPropertyChanges(d.propertyChanges)
            if d.isBinary {
                out("[二进制文件] \(d.statusNotice ?? "无法显示文本差异")")
                continue
            }
            if let notice = d.statusNotice { out("[\(notice)]") }
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
        let client = try await makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let workingCopy = URL(fileURLWithPath: wc)
        let r = try await (args.bool("exact")
            ? client.commitSelection(workingCopy: workingCopy, paths: paths, message: message)
            : client.commit(workingCopy: workingCopy, paths: paths, message: message, progress: nil))
        if r.revision > 0 {
            out("已提交 r\(r.revision)，共 \(r.committedCount) 个条目。")
        } else {
            out("没有可提交的改动。")
        }

    case "revert":
        guard let wc = args.positional.first else { die("需要工作副本目录") }
        let client = try await makeClient(args, workingCopyPath: wc)
        let paths = Array(args.positional.dropFirst())
        let workingCopy = URL(fileURLWithPath: wc)
        let n = try await (args.bool("exact")
            ? client.revertSelection(workingCopy: workingCopy, paths: paths)
            : client.revert(workingCopy: workingCopy, paths: paths))
        out("已回滚 \(n) 个路径。")

    case "proplist", "propget", "propset", "propdel", "ignore", "mkdir":
        try await nodeCommand(command, args)

    case "delete", "move", "rename", "copy", "resolve", "merge":
        let common: Set<String> = ["user", "password", "trust-bundle", "ca", "server"]
        let specific: Set<String>
        switch command {
        case "merge": specific = ["source", "revision", "r", "from", "to", "peg", "dry-run"]
        case "resolve": specific = ["strategy"]
        default: specific = []
        }
        guard args.duplicates.isEmpty, Set(args.flags.keys).isSubset(of: common.union(specific)),
              args.flags.values.allSatisfy({ !$0.isEmpty }) else {
            die("存在重复、未知或缺值的选项")
        }
        let count = args.positional.count
        guard let wc = args.positional.first,
              command == "delete" ? count >= 2 :
              command == "merge" ? count == 1 :
              command == "resolve" ? count == 2 : count == 3 else {
            die("工作副本或文件参数数量不正确，请查看命令帮助")
        }
        let workingCopy = URL(fileURLWithPath: wc)
        let client = try await makeClient(args, workingCopyPath: wc)
        switch command {
        case "delete":
            let paths = try await client.delete(workingCopy: workingCopy, paths: Array(args.positional.dropFirst()))
            out("已在工作副本标记删除，待提交：\(paths.joined(separator: ", "))")
        case "move", "rename", "copy":
            let source = args.positional[1]
            let target = args.positional[2]
            let destination: String
            if command == "rename" {
                guard !target.contains("/"), !target.contains("\\") else { die("改名只接受同目录的新文件名") }
                destination = (source.split(separator: "/", omittingEmptySubsequences: false)
                    .dropLast().map(String.init) + [target]).joined(separator: "/")
            } else {
                destination = target
            }
            if command == "copy" {
                _ = try await client.copy(workingCopy: workingCopy, source: source, destination: destination)
            } else {
                _ = try await client.move(workingCopy: workingCopy, source: source, destination: destination)
            }
            out("工作副本待提交：\(source) → \(destination)")
        case "resolve":
            guard let value = args.string("strategy"), let strategy = ConflictResolution(rawValue: value) else {
                die("请选择 current、base、incoming 或 local")
            }
            try await client.resolve(workingCopy: workingCopy, path: args.positional[1], strategy: strategy)
            out("已解决工作副本中的文本冲突")
        default:
            guard let source = args.string("source"),
                  args.string("dry-run").map({ $0 == "true" || $0 == "false" }) ?? true else {
                die("需要 --source URL，--dry-run 为布尔选项")
            }
            let url = requireURL(source)
            let peg = args.int("peg")
            if args.string("peg") != nil && peg == nil { die("无效的 peg 修订") }
            let request: MergeRequest
            if let raw = args.string("revision") ?? args.string("r") {
                guard !(args.string("revision") != nil && args.string("r") != nil),
                      args.string("from") == nil, args.string("to") == nil,
                      let revision = Int(raw) else { die("请只指定一个有效的单修订或范围") }
                request = try MergeRequest(source: url, revision: revision, peg: peg)
            } else {
                guard let from = args.int("from"), let to = args.int("to") else {
                    die("需要 --revision N 或 --from A --to B")
                }
                request = try MergeRequest(source: url, from: from, to: to, peg: peg)
            }
            let result = try await client.merge(workingCopy: workingCopy, request: request, dryRun: args.bool("dry-run"))
            out(result.dryRun ? "合并预演，工作副本未写入" : "合并已应用到工作副本，尚未提交")
            for path in result.changedPaths { out("变更：\(path)") }
            for path in result.conflictedPaths { out("冲突：\(path)") }
            for path in result.skippedPaths { out("跳过：\(path)") }
            if result.changedPaths.isEmpty && result.conflictedPaths.isEmpty &&
                result.skippedPaths.isEmpty && !result.refreshRequired { out("没有可合并的变更。") }
            if result.refreshRequired { out("合并已应用，读取实际状态失败，请刷新工作副本状态。") }
            if !result.conflictedPaths.isEmpty { exit(2) }
        }

    case "log":
        guard let target = args.positional.first else { die("需要工作副本目录或仓库 URL") }
        // 既支持工作副本路径，也支持直接给仓库 URL
        let client = try await makeClient(args, url: target)
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
        guard let rev = Int(cleanRevStr), (1...Int(Int32.max)).contains(rev) else {
            die("无效的修订号：\(revRaw)")
        }

        let client = try await makeClient(args, url: target)
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
            printPropertyChanges(d.propertyChanges)
            if d.isBinary {
                out("[二进制文件] \(d.statusNotice ?? "无法显示文本差异")")
                continue
            }
            if let notice = d.statusNotice {
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
