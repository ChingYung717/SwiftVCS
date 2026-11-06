import AppKit
import CVCSKit
import CSVNKit
import Foundation
import SwiftUI

@main
struct VCSExplorerApp: App {
    @StateObject private var model = AppModel()

    init() {
        let args = CommandLine.arguments
        // --selftest <仓库URL> [工作副本路径]：走与界面完全相同的模型路径做端到端验证
        if let i = args.firstIndex(of: "--selftest") {
            guard i + 1 < args.count, !args[i + 1].isEmpty, !args[i + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("需要 --selftest <仓库URL> [工作副本路径]\n".utf8))
                exit(1)
            }
            let url = args[i + 1]
            let wc = i + 2 < args.count ? args[i + 2] : ""
            Task { @MainActor in
                let checks = await AppModel.selfTest(url: url, workingCopy: wc)
                for check in checks {
                    print("\(check.passed ? "✅" : "❌") \(check.name)：\(check.detail)")
                }
                exit(checks.allSatisfy(\.passed) ? 0 : 1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("VCS Explorer") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
                .task { model.applyLaunchArguments() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - 应用主状态模型

@MainActor
final class AppModel: ObservableObject {

    // MARK: 连接与凭据
    @Published var repoURLString = "" {
        didSet {
            if normalizedRepoURL(oldValue) != normalizedRepoURL(repoURLString) {
                password = ""
                pendingProbedCertificate = nil
            }
        }
    }
    @Published var username = "" {
        didSet {
            if oldValue != username { password = "" }
        }
    }
    @Published var password = ""
    @Published var repoInfo: RepositoryInfo?
    @Published var recentRepos: [String] = []
    @Published var showConnectSheet = false
    @Published var showRepoPopover = false
    @Published var showWorkspacePopover = false
    @Published var lastRefresh: Date?

    // MARK: 导航页签
    @Published var sidebarTab: SidebarTab = .history

    // MARK: 仓库浏览（Browse）
    @Published var entries: [RepositoryEntry] = []
    @Published var currentPath: String = ""
    @Published var selectedEntry: RepositoryEntry?
    @Published var previewText: String?
    @Published var previewTitle: String?
    @Published var isPreviewBinary = false
    @Published var isPreviewLoading = false

    // MARK: 工作副本（Changes）
    @Published var workingCopyPath = "" {
        didSet {
            if oldValue != workingCopyPath {
                workspaceOperation = nil
                propertyInspection = nil
                mergeResult = nil
                mergeError = nil
                updateConflicts = []
                pendingRevertStatus = nil
            }
        }
    }
    @Published var statuses: [WorkingCopyStatus] = []
    @Published var selectedStatus: WorkingCopyStatus?
    @Published var showAllStatuses = false
    @Published var checkedPaths: Set<String> = []
    @Published var commitSummary = ""
    @Published var commitDescription = ""
    @Published var workingDiffState: FileDiffLoadState = .idle

    // MARK: 历史与提交级文件比对（History & Commit Diff）
    @Published var logs: [LogEntry] = []
    @Published var selectedRevision: Int?
    @Published var selectedChangedItem: UIChangedItem?
    @Published var fileDiffState: FileDiffLoadState = .idle
    @Published var historySearchQuery: String = ""
    @Published var customLogPath: String? = nil
    @Published var hasMoreLogs = false
    @Published var isLoadingMoreLogs = false

    @Published var workspaceOperation: WorkspaceOperation?
    @Published var operationDestination = ""
    @Published var mkdirParents = false
    @Published var mkdirPreview: DirectoryPreview?
    @Published var propertyInspection: PropertyInspection?
    @Published var nodeProperties: [NodeProperty] = []
    @Published var nodeIgnoreRules: IgnoreRules?
    @Published var propertyFeedback: String?
    @Published var propertyName = ""
    @Published var propertyValue = ""
    @Published var pendingPropertyDeletion: String?
    @Published var mergeSource = ""
    @Published var mergeRange = ""
    @Published var mergePeg = ""
    @Published var mergeResult: MergeResult?
    @Published var mergeError: String?
    @Published var updateConflicts: [String] = []

    // MARK: 证书与状态提示
    @Published var rememberPassword = false
    @Published var trustedHosts: [String] = []
    @Published var trustedCertificates: [TrustStore.CertificateInfo] = []
    @Published var pendingProbedCertificate: TrustStore.ProbedCertificate? = nil
    @Published var certificateIssue: String?
    @Published var errorText: String?
    @Published var isBusy = false
    @Published var statusText = ""

    // MARK: 界面局部状态（避免依赖 CommandLineTools 缺失的 SwiftUIMacros.@State 宏）
    @Published var now = Date()
    @Published var browseSearchQuery = ""
    @Published var commitFileFilterQuery = ""
    @Published var pendingRevertStatus: WorkingCopyStatus? = nil
    @Published var showAllDiffLines = false
    @Published var showAllPreviewLines = false

    private var client: SVNClient?
    private var isSelfTest = false
    private var busyCount = 0

    /// 提交级文件比对内存缓存（key = "rev|path"，LRU 上限 200）
    private var revisionDiffCache: [String: FileDiff] = [:]
    private var revisionDiffCacheOrder: [String] = []
    private let maxCacheEntries = 200

    /// 异步比对与预览任务句柄（切换提交或文件时立即 cancel 防止旧结果串台）
    private var diffTask: Task<Void, Never>?
    private var workingDiffTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init() {
        refreshTrustedCertificates()
        let saved = AppSettingsStore.load()
        repoURLString = saved.repoURL
        username = saved.username
        rememberPassword = saved.rememberPassword
        recentRepos = saved.recentRepos
        if !saved.workingCopyPath.isEmpty,
           FileManager.default.fileExists(atPath: saved.workingCopyPath) {
            workingCopyPath = saved.workingCopyPath
        }
    }

    // MARK: - 派生计算属性

    var currentSelectedLog: LogEntry? {
        guard let rev = selectedRevision else { return logs.first }
        return logs.first(where: { $0.revision == rev })
    }

    var currentCommitChanges: [UIChangedItem] {
        guard let log = currentSelectedLog else { return [] }
        return UIChangedItem.extract(from: log)
    }

    var displayedWorkingStatuses: [WorkingCopyStatus] {
        if showAllStatuses {
            return statuses
        }
        return statuses.filter { $0.kind != .normal && $0.kind != .ignored }
    }

    var committableWorkingStatuses: [WorkingCopyStatus] {
        statuses.filter { $0.kind != .normal && $0.kind != .ignored }
    }

    var pendingChangesCount: Int {
        committableWorkingStatuses.count
    }

    var areAllChangesChecked: Bool {
        let candidates = committableWorkingStatuses.map(\.path)
        guard !candidates.isEmpty else { return false }
        return candidates.allSatisfy { checkedPaths.contains($0) }
    }

    func setAllChangesChecked(_ checked: Bool) {
        if checked {
            for s in committableWorkingStatuses {
                checkedPaths.insert(s.path)
            }
        } else {
            checkedPaths.removeAll()
        }
    }

    func pairedPaths(for path: String) -> Set<String> {
        var paths: Set<String> = [path]
        var pending = [path]
        while let next = pending.popLast(), let row = statuses.first(where: { $0.path == next }) {
            for partner in [row.movedFrom, row.movedTo].compactMap({ $0 }) where paths.insert(partner).inserted {
                pending.append(partner)
            }
        }
        return paths
    }

    func bindingForCheckedPath(_ path: String) -> Binding<Bool> {
        Binding(
            get: { self.checkedPaths.contains(path) },
            set: { isOn in
                let paths = self.pairedPaths(for: path)
                if isOn { self.checkedPaths.formUnion(paths) }
                else { self.checkedPaths.subtract(paths) }
            }
        )
    }

    // MARK: - 内部辅助

    private func normalizedRepoURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") && trimmed.count > 1 && !trimmed.hasSuffix("://") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private func saveCurrentSettings() {
        guard !isSelfTest else { return }
        var s = AppSettingsStore.load()
        let cleanURL = normalizedRepoURL(repoURLString)
        if !cleanURL.isEmpty, !cleanURL.contains("swiftvcs-e2e") {
            s.repoURL = cleanURL
            if !s.recentRepos.contains(cleanURL) {
                s.recentRepos.insert(cleanURL, at: 0)
                if s.recentRepos.count > 8 {
                    s.recentRepos = Array(s.recentRepos.prefix(8))
                }
            }
            recentRepos = s.recentRepos
        }
        if !username.isEmpty { s.username = username }
        if !workingCopyPath.contains("swiftvcs-e2e") {
            s.workingCopyPath = workingCopyPath
        }
        s.rememberPassword = rememberPassword
        AppSettingsStore.save(s)
    }

    private func refreshTrustedCertificates() {
        let certs = TrustStore.shared.importedCertificates()
        trustedCertificates = certs
        trustedHosts = certs.map { $0.name }
    }

    private func ensureClient() throws -> SVNClient {
        if let c = client { return c }

        refreshTrustedCertificates()

        var resolvedRepoURL = repoInfo?.url
        if resolvedRepoURL == nil, !workingCopyPath.isEmpty {
            if let wcURL = SVNClient.workingCopyURL(at: URL(fileURLWithPath: workingCopyPath)) {
                resolvedRepoURL = wcURL
                if repoURLString.isEmpty {
                    repoURLString = wcURL.absoluteString
                }
            }
        }
        if resolvedRepoURL == nil {
            resolvedRepoURL = URL(string: normalizedRepoURL(repoURLString))
        }
        let c = try SVNClient(
            username: username.isEmpty ? nil : username,
            password: resolvedRepoURL?.absoluteString == normalizedRepoURL(repoURLString) && !password.isEmpty
                ? password : nil,
            baseURL: resolvedRepoURL,
            useSavedCredentials: rememberPassword
        )
        client = c
        return c
    }

    private func clientForWorkingCopy() throws -> SVNClient {
        let wc = URL(fileURLWithPath: workingCopyPath)
        if let url = SVNClient.workingCopyURL(at: wc),
           url.absoluteString != normalizedRepoURL(repoURLString) {
            return try SVNClient(username: username.isEmpty ? nil : username, baseURL: url,
                                 useSavedCredentials: rememberPassword)
        }
        return try ensureClient()
    }

    private func putCache(key: String, diff: FileDiff) {
        revisionDiffCache[key] = diff
        revisionDiffCacheOrder.removeAll { $0 == key }
        revisionDiffCacheOrder.append(key)
        if revisionDiffCacheOrder.count > maxCacheEntries, let oldest = revisionDiffCacheOrder.first {
            revisionDiffCacheOrder.removeFirst()
            revisionDiffCache.removeValue(forKey: oldest)
        }
    }

    // MARK: - 核心操作（可 await、供界面与 --selftest 共用）

    func connectCore() async throws -> RepositoryInfo {
        let cleanURL = normalizedRepoURL(repoURLString)
        guard let url = URL(string: cleanURL), (url.isFileURL && url.user == nil && url.password == nil) || SVNOrigin(url) != nil else {
            throw VCSError.invalidArgument("请输入合法的仓库 URL，并在认证栏填写凭据")
        }

        refreshTrustedCertificates()
        let submittedUser = username
        let submittedPassword = password
        let c = try SVNClient(
            username: submittedUser.isEmpty ? nil : submittedUser,
            password: submittedPassword.isEmpty ? nil : submittedPassword,
            baseURL: url,
            useSavedCredentials: rememberPassword
        )
        do {
            let info = try await c.connect(to: url, credentials: nil)
            guard normalizedRepoURL(repoURLString) == cleanURL,
                  username == submittedUser, password == submittedPassword else {
                throw VCSError.invalidArgument("连接设置已更改，请重新连接")
            }
            diffTask?.cancel()
            previewTask?.cancel()
            revisionDiffCache.removeAll()
            revisionDiffCacheOrder.removeAll()
            customLogPath = nil
            selectedRevision = nil
            selectedChangedItem = nil
            fileDiffState = .idle
            previewText = nil
            previewTitle = nil
            isPreviewLoading = false

            client = c
            repoInfo = info
            certificateIssue = nil
            lastRefresh = Date()

            if rememberPassword, !submittedPassword.isEmpty, SVNOrigin(url)?.scheme == "https" {
                do {
                    _ = try await c.rememberPassword()
                } catch {
                    errorText = error.localizedDescription
                }
            }
            saveCurrentSettings()

            _ = try await browseCore(path: nil)
            return info
        } catch {
            let desc = (error as? VCSError)?.errorDescription ?? "\(error)"
            if desc.localizedCaseInsensitiveContains("certificate") ||
               desc.localizedCaseInsensitiveContains("SSL") ||
               desc.localizedCaseInsensitiveContains("TLS") {
                certificateIssue = desc
            }
            throw error
        }
    }

    @discardableResult
    func browseCore(path: String?) async throws -> [RepositoryEntry] {
        let c = try ensureClient()
        let normalizedPath: String?
        if let p = path, !p.isEmpty {
            normalizedPath = p.hasSuffix("/") ? String(p.dropLast()) : p
        } else {
            normalizedPath = nil
        }
        let items = try await c.browse(path: normalizedPath)
        previewTask?.cancel()
        isPreviewLoading = false
        showAllPreviewLines = false
        entries = items.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) {
                return $0.kind == .directory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        currentPath = normalizedPath ?? ""
        selectedEntry = nil
        previewText = nil
        previewTitle = nil
        lastRefresh = Date()
        return entries
    }

    func checkoutCore(entry: RepositoryEntry?, destination: URL? = nil) async throws -> URL {
        let c = try ensureClient()
        let dest = destination ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("checkout-\(UUID().uuidString.prefix(6))")

        var path: String? = nil
        if let e = entry {
            if e.kind == .directory {
                var p = e.path
                if p.hasSuffix("/") { p.removeLast() }
                path = p.isEmpty ? nil : p
            } else {
                if let idx = e.path.lastIndex(of: "/") {
                    path = String(e.path[e.path.startIndex..<idx])
                } else {
                    path = currentPath.isEmpty ? nil : currentPath
                }
            }
        } else if !currentPath.isEmpty {
            path = currentPath
        }

        let url = try await c.checkout(path: path, to: dest, revision: nil)
        workingCopyPath = url.path
        saveCurrentSettings()
        try await refreshStatusCore()
        return url
    }

    func refreshStatusCore() async throws {
        guard !workingCopyPath.isEmpty else { return }
        let c = try ensureClient()
        let oldCommittablePaths = Set(statuses.filter { $0.kind != .normal && $0.kind != .ignored }.map(\.path))
        let previousChecked = checkedPaths
        let path = workingCopyPath
        let newStatuses = try await c.status(of: URL(fileURLWithPath: path))
        guard workingCopyPath == path else { return }
        statuses = newStatuses
        updateConflicts = newStatuses.filter { $0.kind == .conflicted }.map(\.path).sorted()
        lastRefresh = Date()

        let newCommittablePaths = Set(newStatuses.filter { $0.kind != .normal && $0.kind != .ignored }.map(\.path))
        if !previousChecked.isEmpty {
            // 保留仍在可提交列表中的已勾选路径，并仅对新增出现的待提交文件自动勾选
            let kept = previousChecked.intersection(newCommittablePaths)
            let newlyAppeared = newCommittablePaths.subtracting(oldCommittablePaths)
            checkedPaths = kept.union(newlyAppeared)
        } else {
            checkedPaths = newCommittablePaths
        }

        if let sel = selectedStatus, let refreshed = newStatuses.first(where: { $0.path == sel.path }) {
            if sel != refreshed { selectWorkingStatus(refreshed) }
        } else if let firstChanged = newStatuses.first(where: { $0.kind != .normal && $0.kind != .ignored }) {
            selectWorkingStatus(firstChanged)
        } else {
            selectedStatus = nil
            workingDiffState = .idle
        }
        saveCurrentSettings()
    }

    func updateCore() async throws -> UpdateResult {
        let c = try clientForWorkingCopy()
        let path = workingCopyPath
        let r = try await c.update(
            workingCopy: URL(fileURLWithPath: path),
            revision: nil,
            progress: nil
        )
        guard workingCopyPath == path else { return r }
        await refreshAfterWrite(path: path)
        if !r.conflicts.isEmpty {
            updateConflicts = Array(Set(updateConflicts).union(r.conflicts.map {
                $0.hasPrefix(path + "/") ? String($0.dropFirst(path.count + 1)) : $0
            })).sorted()
        }
        return r
    }

    func diffCore(forPaths specificPaths: [String]? = nil) async throws -> [FileDiff] {
        let c = try clientForWorkingCopy()
        let paths = specificPaths ?? statuses.filter { $0.kind.isPendingChange }.map(\.path)
        if paths.isEmpty && specificPaths == nil {
            return []
        }
        return try await c.diff(workingCopy: URL(fileURLWithPath: workingCopyPath), paths: paths)
    }

    func logCore(customPath: String? = nil, limit: Int = 50, startRevision: Int? = nil) async throws -> [LogEntry] {
        let c = try ensureClient()
        let targetURL: URL
        let subPath: String?

        if let cp = customPath {
            guard let base = repoInfo?.url ?? URL(string: normalizedRepoURL(repoURLString)) else {
                throw VCSError.underlying("尚未连接仓库")
            }
            targetURL = base
            subPath = cp.isEmpty ? nil : cp
        } else if let base = repoInfo?.url ?? URL(string: normalizedRepoURL(repoURLString)), base.scheme != nil {
            targetURL = base
            subPath = nil
        } else if !workingCopyPath.isEmpty {
            targetURL = URL(fileURLWithPath: workingCopyPath)
            subPath = nil
        } else {
            throw VCSError.underlying("请先连接仓库或指定本地工作副本路径")
        }

        let fetched = try await c.log(
            workingCopy: targetURL,
            path: subPath,
            limit: limit,
            startRevision: startRevision
        )
        lastRefresh = Date()

        if startRevision == nil {
            logs = fetched
            hasMoreLogs = fetched.count >= limit && (fetched.last?.revision ?? 0) > 1
            if let currentRev = selectedRevision, fetched.contains(where: { $0.revision == currentRev }) {
                selectRevision(currentRev)
            } else if let first = fetched.first {
                selectRevision(first.revision)
            } else {
                selectedRevision = nil
                selectedChangedItem = nil
                fileDiffState = .idle
            }
        }
        return fetched
    }

    func commitCore(message: String, specificPaths: [String]? = nil) async throws -> CommitResult {
        let c = try clientForWorkingCopy()
        let path = workingCopyPath
        let paths = specificPaths ?? committableWorkingStatuses.map(\.path)
        let r: CommitResult
        do {
            r = try await c.commitSelection(workingCopy: URL(fileURLWithPath: path), paths: paths, message: message)
        } catch {
            if workingCopyPath == path { try? await refreshStatusCore() }
            throw error
        }
        if workingCopyPath == path {
            commitSummary = ""
            commitDescription = ""
            await refreshAfterWrite(path: path)
        }
        return r
    }

    func revertCore(_ item: WorkingCopyStatus) async throws {
        let c = try clientForWorkingCopy()
        let path = workingCopyPath
        _ = try await c.revertSelection(workingCopy: URL(fileURLWithPath: path),
                                        paths: pairedPaths(for: item.path).sorted())
        await refreshAfterWrite(path: path)
    }

    func addCore(_ item: WorkingCopyStatus) async throws {
        let c = try clientForWorkingCopy()
        let path = workingCopyPath
        _ = try await c.add(workingCopy: URL(fileURLWithPath: path), paths: [item.path])
        await refreshAfterWrite(path: path)
    }

    private func refreshAfterWrite(path: String) async {
        guard workingCopyPath == path else { return }
        do {
            try await refreshStatusCore()
        } catch {
            errorText = "操作已完成，刷新失败：\(error.localizedDescription)"
        }
    }

    func previewFileCore(_ entry: RepositoryEntry) async throws {
        guard entry.kind == .file else { return }
        showAllPreviewLines = false
        previewText = nil
        previewTitle = entry.path
        isPreviewBinary = false
        isPreviewLoading = true
        defer {
            if selectedEntry == nil || selectedEntry?.path == entry.path {
                isPreviewLoading = false
            }
        }

        let c = try ensureClient()

        if FileIcon.isKnownBinaryExtension(entry.name) {
            isPreviewBinary = true
            let sizeStr = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知大小"
            previewText = "二进制文件（\(entry.name)，\(sizeStr)），不支持纯文本预览。"
            return
        }

        if let sz = entry.size, sz > 2 * 1024 * 1024 {
            isPreviewBinary = true
            previewText = "文件较大（\(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))），为避免卡顿已跳过在线文本预览。可检出工作副本后在本地打开。"
            return
        }

        do {
            let data = try await c.cat(path: entry.path, revision: nil)
            guard !Task.isCancelled else { return }
            guard selectedEntry == nil || selectedEntry?.path == entry.path else { return }
            if SVNClient.looksBinaryData(data) {
                isPreviewBinary = true
                previewText = "二进制文件（\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))），不支持纯文本预览。"
            } else if let text = SVNClient.decodeText(data) {
                isPreviewBinary = false
                previewText = text
            } else {
                isPreviewBinary = true
                previewText = "非 UTF-8/GB18030 文本或二进制文件（\(data.count) 字节）。"
            }
        } catch {
            guard !Task.isCancelled else { return }
            if selectedEntry == nil || selectedEntry?.path == entry.path {
                let msg = (error as? VCSError)?.errorDescription ?? "\(error)"
                isPreviewBinary = true
                previewText = "读取文件预览失败：\(msg)"
            }
            throw error
        }
    }

    // MARK: - 提交级文件比对（核心新增能力）

    func selectRevision(_ revision: Int) {
        if selectedRevision != revision {
            commitFileFilterQuery = ""
        }
        selectedRevision = revision
        guard let log = logs.first(where: { $0.revision == revision }) else {
            selectedChangedItem = nil
            fileDiffState = .idle
            return
        }
        let changes = UIChangedItem.extract(from: log)
        // 优先自动选中第一个非目录的文件改动
        if let prev = selectedChangedItem,
           let matched = changes.first(where: { $0.path == prev.path }) {
            selectChangedItem(matched, inRevision: revision)
        } else if let firstFile = changes.first(where: { !$0.isDirectory }) ?? changes.first {
            selectChangedItem(firstFile, inRevision: revision)
        } else {
            selectedChangedItem = nil
            fileDiffState = .idle
        }
    }

    func selectChangedItem(_ item: UIChangedItem, inRevision explicitRevision: Int? = nil) {
        let rev = explicitRevision ?? selectedRevision
        selectedChangedItem = item
        showAllDiffLines = false
        guard let rev else {
            fileDiffState = .idle
            return
        }
        loadRevisionFileDiff(revision: rev, item: item)
    }

    func reloadCurrentCommitFileDiff() {
        guard let rev = selectedRevision, let item = selectedChangedItem else { return }
        let cacheKey = "\(rev)|\(item.path)"
        revisionDiffCache.removeValue(forKey: cacheKey)
        loadRevisionFileDiff(revision: rev, item: item)
    }

    private func loadRevisionFileDiff(revision: Int, item: UIChangedItem) {
        diffTask?.cancel()

        if isSelfTest { return }

        let cacheKey = "\(revision)|\(item.path)"
        if let cached = revisionDiffCache[cacheKey] {
            fileDiffState = .loaded(cached, isTruncated: cached.isTruncated)
            return
        }

        fileDiffState = .loading
        let targetChange = item.toChangedPath()

        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let c = try self.ensureClient()
                let rootURL = self.repoInfo?.rootURL ?? c.repositoryRoot
                let diff = try await c.diffFile(
                    revision: revision,
                    change: targetChange,
                    repoRootURL: rootURL,
                    maxBytes: 2 * 1024 * 1024
                )
                guard !Task.isCancelled else { return }
                guard self.selectedRevision == revision,
                      self.selectedChangedItem?.path == item.path else { return }

                self.putCache(key: cacheKey, diff: diff)
                self.fileDiffState = .loaded(diff, isTruncated: diff.isTruncated)
            } catch {
                guard !Task.isCancelled else { return }
                guard self.selectedRevision == revision,
                      self.selectedChangedItem?.path == item.path else { return }
                let msg = (error as? VCSError)?.errorDescription ?? "\(error)"
                self.fileDiffState = .failed(msg)
            }
        }
    }

    // MARK: - 界面交互方法

    func selectSidebarTab(_ tab: SidebarTab) {
        sidebarTab = tab
        switch tab {
        case .history:
            if logs.isEmpty && (repoInfo != nil || !workingCopyPath.isEmpty) {
                showLog(customPath: customLogPath)
            }
        case .changes:
            if !workingCopyPath.isEmpty && statuses.isEmpty {
                reloadStatus()
            }
        case .browse:
            if entries.isEmpty && repoInfo != nil {
                browse(path: currentPath.isEmpty ? nil : currentPath)
            }
        }
    }

    func selectAdjacentSidebarItem(delta: Int) {
        switch sidebarTab {
        case .history:
            guard !logs.isEmpty else { return }
            let curIdx = logs.firstIndex(where: { $0.revision == selectedRevision }) ?? 0
            let nextIdx = max(0, min(logs.count - 1, curIdx + delta))
            selectRevision(logs[nextIdx].revision)
        case .changes:
            let list = displayedWorkingStatuses
            guard !list.isEmpty else { return }
            let curIdx = list.firstIndex(where: { $0.path == selectedStatus?.path }) ?? 0
            let nextIdx = max(0, min(list.count - 1, curIdx + delta))
            selectWorkingStatus(list[nextIdx])
        case .browse:
            guard !entries.isEmpty else { return }
            let curIdx = entries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
            let nextIdx = max(0, min(entries.count - 1, curIdx + delta))
            selectBrowseEntry(entries[nextIdx])
        }
    }

    func selectAdjacentCommitFile(delta: Int) {
        let changes = currentCommitChanges
        guard !changes.isEmpty else { return }
        let curIdx = changes.firstIndex(where: { $0.path == selectedChangedItem?.path }) ?? 0
        let nextIdx = max(0, min(changes.count - 1, curIdx + delta))
        selectChangedItem(changes[nextIdx])
    }

    func applyLaunchArguments() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { return }

        if let i = args.firstIndex(of: "--repo"), i + 1 < args.count {
            repoURLString = args[i + 1]
        }
        if let i = args.firstIndex(of: "--user"), i + 1 < args.count {
            username = args[i + 1]
        }
        if let i = args.firstIndex(of: "--password"), i + 1 < args.count {
            password = args[i + 1]
        }
        if let i = args.firstIndex(of: "--wc"), i + 1 < args.count {
            workingCopyPath = args[i + 1]
        }

        if !repoURLString.isEmpty {
            connect()
        } else if !workingCopyPath.isEmpty {
            sidebarTab = .changes
            reloadStatus()
        }
    }

    func connect(dismissSheetOnSuccess: Bool = false) {
        run {
            let info = try await self.connectCore()
            // 连接成功后同步拉取最新提交历史
            _ = try? await self.logCore(customPath: self.customLogPath)
            if !self.workingCopyPath.isEmpty,
               FileManager.default.fileExists(atPath: self.workingCopyPath) {
                try? await self.refreshStatusCore()
            }
            if dismissSheetOnSuccess {
                self.showConnectSheet = false
            }
            self.statusText = "已连接 \(info.url.lastPathComponent.isEmpty ? info.url.absoluteString : info.url.lastPathComponent)，最新修订 r\(info.youngestRevision)"
        }
    }

    /// 第一步：抓取并展示叶证书的指纹，供用户独立核验。
    func probeServerCertificate() {
        let cleanURL = normalizedRepoURL(repoURLString)
        guard let url = URL(string: cleanURL), let origin = SVNOrigin(url), origin.scheme == "https" else {
            errorText = "请输入合法的 HTTPS 仓库 URL"
            return
        }
        run {
            let probed = try await Task.detached(priority: .userInitiated) {
                try TrustStore.shared.probeCertificate(host: origin.host, port: origin.port)
            }.value
            guard self.normalizedRepoURL(self.repoURLString) == cleanURL else { return }
            self.pendingProbedCertificate = probed
            self.statusText = "已获取 \(origin.endpoint) 证书，请核对 SHA-256 指纹"
        }
    }

    /// 第二步：用户核验后，仅为该 HTTPS 端点保存叶证书。
    func confirmPendingCertificateAndConnect(dismissOnSuccess: Bool = false) {
        guard let probed = pendingProbedCertificate else { return }
        run {
            guard let url = URL(string: self.normalizedRepoURL(self.repoURLString)) else {
                throw VCSError.invalidArgument("仓库地址已更改，请重新获取证书")
            }
            try TrustStore.shared.trust(probed, for: url)
            self.pendingProbedCertificate = nil
            self.refreshTrustedCertificates()
            let info = try await self.connectCore()
            _ = try? await self.logCore(customPath: self.customLogPath)
            if dismissOnSuccess {
                self.showConnectSheet = false
            }
            self.statusText = "已信任 \(probed.host):\(probed.port) 的证书并连接 \(info.url)"
        }
    }

    func cancelPendingCertificate() {
        pendingProbedCertificate = nil
    }

    func trustServerCertificateAndConnect(dismissOnSuccess: Bool = false) {
        showConnectSheet = true
        probeServerCertificate()
    }

    func removeTrustedCertificate(_ name: String) {
        run {
            try TrustStore.shared.removeCertificate(name: name)
            if (self.repoInfo?.url).flatMap(SVNOrigin.init)?.endpoint == name {
                self.disconnect()
            }
            self.refreshTrustedCertificates()
            self.statusText = "已移除证书 \(name)"
        }
    }

    func disconnect() {
        diffTask?.cancel()
        workingDiffTask?.cancel()
        previewTask?.cancel()
        client = nil
        password = ""
        pendingProbedCertificate = nil
        repoInfo = nil
        propertyInspection = nil
        entries = []
        logs = []
        currentPath = ""
        selectedEntry = nil
        selectedRevision = nil
        selectedChangedItem = nil
        fileDiffState = .idle
        previewText = nil
        previewTitle = nil
        isPreviewBinary = false
        isPreviewLoading = false
        showAllPreviewLines = false
        customLogPath = nil
        hasMoreLogs = false
        isLoadingMoreLogs = false
        historySearchQuery = ""
        lastRefresh = nil
        revisionDiffCache.removeAll()
        revisionDiffCacheOrder.removeAll()
        statusText = "已断开连接"
    }

    func clearWorkingCopy() {
        workingCopyPath = ""
        statuses = []
        selectedStatus = nil
        checkedPaths.removeAll()
        workingDiffState = .idle
        saveCurrentSettings()
        statusText = "已移除本地工作副本关联"
    }

    func refreshAll() {
        run {
            if self.repoInfo != nil || !self.repoURLString.isEmpty {
                if self.repoInfo == nil {
                    _ = try await self.connectCore()
                } else {
                    _ = try? await self.browseCore(path: self.currentPath.isEmpty ? nil : self.currentPath)
                }
                _ = try await self.logCore(customPath: self.customLogPath)
            }
            if !self.workingCopyPath.isEmpty,
               FileManager.default.fileExists(atPath: self.workingCopyPath) {
                try await self.refreshStatusCore()
            }
            self.lastRefresh = Date()
            self.statusText = "已刷新最新仓库历史与状态"
        }
    }

    func browse(path: String?) {
        run {
            let items = try await self.browseCore(path: path)
            self.statusText = "目录 /\(self.currentPath) 共 \(items.count) 个条目"
        }
    }

    func selectBrowseEntry(_ entry: RepositoryEntry) {
        selectedEntry = entry
        if entry.kind == .file {
            previewEntry(entry)
        } else {
            previewTask?.cancel()
            isPreviewLoading = false
            previewText = nil
            previewTitle = nil
            showAllPreviewLines = false
        }
    }

    func open(_ entry: RepositoryEntry) {
        selectedEntry = entry
        if entry.kind == .directory {
            var p = entry.path
            if p.hasSuffix("/") { p.removeLast() }
            browse(path: p)
        } else {
            previewEntry(entry)
        }
    }

    func previewEntry(_ entry: RepositoryEntry) {
        previewTask?.cancel()
        selectedEntry = entry
        guard entry.kind == .file else {
            isPreviewLoading = false
            previewText = nil
            previewTitle = nil
            return
        }
        showAllPreviewLines = false
        previewText = nil
        previewTitle = entry.path
        isPreviewBinary = false
        isPreviewLoading = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.previewFileCore(entry)
                guard !Task.isCancelled, self.selectedEntry?.path == entry.path else { return }
                self.statusText = "已加载文件预览：\(entry.name)"
            } catch {
                guard !Task.isCancelled, self.selectedEntry?.path == entry.path else { return }
                let msg = (error as? VCSError)?.errorDescription ?? "\(error)"
                self.errorText = msg
            }
        }
    }

    func showLogForEntry(_ entry: RepositoryEntry) {
        var clean = entry.path
        if clean.hasSuffix("/") { clean.removeLast() }
        showLogForPath(clean)
    }

    /// 若当前连接的仓库 URL 已经是子目录（如 .../repo/trunk），严格按 `/` 路径边界剥离重复前缀
    private static func stripSubRepoPrefix(path: String, base: URL, root: URL) -> String {
        var clean = path
        var baseStr = base.path
        var rootStr = root.path
        while baseStr.count > 1 && baseStr.hasSuffix("/") { baseStr.removeLast() }
        while rootStr.count > 1 && rootStr.hasSuffix("/") { rootStr.removeLast() }

        let isSubPath: Bool
        if rootStr == "/" {
            isSubPath = baseStr.count > 1 && baseStr.hasPrefix("/")
        } else {
            isSubPath = baseStr.count > rootStr.count && baseStr.hasPrefix(rootStr + "/")
        }
        guard isSubPath else { return clean }

        var subPrefix = rootStr == "/" ? String(baseStr.dropFirst(1)) : String(baseStr.dropFirst(rootStr.count))
        if subPrefix.hasPrefix("/") { subPrefix.removeFirst() }
        if subPrefix.hasSuffix("/") { subPrefix.removeLast() }
        guard !subPrefix.isEmpty else { return clean }

        if clean == subPrefix {
            clean = ""
        } else if clean.hasPrefix(subPrefix + "/") {
            clean = String(clean.dropFirst(subPrefix.count + 1))
        }
        return clean
    }

    func showLogForPath(_ path: String) {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("/") { clean.removeFirst() }
        if clean.hasSuffix("/") { clean.removeLast() }

        if let base = repoInfo?.url, let root = repoInfo?.rootURL {
            clean = Self.stripSubRepoPrefix(path: clean, base: base, root: root)
        }

        customLogPath = clean.isEmpty ? nil : clean
        sidebarTab = .history
        showLog(customPath: customLogPath)
    }

    func browseDirectoryOfCommit(_ log: LogEntry) {
        let items = UIChangedItem.extract(from: log)
        guard let first = items.first else { return }
        var clean = (first.isDirectory ? first.path : first.directoryPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("/") { clean.removeFirst() }
        if clean.hasSuffix("/") { clean.removeLast() }

        if let base = repoInfo?.url, let root = repoInfo?.rootURL {
            clean = Self.stripSubRepoPrefix(path: clean, base: base, root: root)
        }

        sidebarTab = .browse
        browse(path: clean.isEmpty ? nil : clean)
    }

    func goUp() {
        var p = currentPath
        guard !p.isEmpty else { return }
        if let idx = p.lastIndex(of: "/") {
            p = String(p[p.startIndex..<idx])
        } else {
            p = ""
        }
        browse(path: p.isEmpty ? nil : p)
    }

    func checkout(entry: RepositoryEntry?) {
        run {
            let url = try await self.checkoutCore(entry: entry)
            self.sidebarTab = .changes
            self.statusText = "已检出到 \(url.path)"
        }
    }

    func checkoutWithPanel(entry: RepositoryEntry?) {
        let panel = NSOpenPanel()
        panel.title = "选择检出目标目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "检出到此目录"
        if panel.runModal() == .OK, let folder = panel.url {
            let subName: String
            if let e = entry, e.kind == .directory {
                subName = e.name
            } else if !currentPath.isEmpty {
                subName = currentPath.split(separator: "/").last.map(String.init) ?? "working-copy"
            } else if let repoLast = URL(string: normalizedRepoURL(repoURLString))?.lastPathComponent, !repoLast.isEmpty {
                subName = repoLast
            } else {
                subName = "working-copy"
            }
            let dest = folder.appendingPathComponent(subName)
            run {
                let url = try await self.checkoutCore(entry: entry, destination: dest)
                self.sidebarTab = .changes
                self.statusText = "已检出到 \(url.path)"
            }
        }
    }

    func chooseWorkingCopyDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择已有本地 SVN 工作副本目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作副本"
        if panel.runModal() == .OK, let folder = panel.url {
            workingCopyPath = folder.path
            sidebarTab = .changes
            reloadStatus()
        }
    }

    func revealWorkingCopyInFinder() {
        guard !workingCopyPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workingCopyPath)
    }

    func revealStatusItemInFinder(_ item: WorkingCopyStatus) {
        guard !workingCopyPath.isEmpty else { return }
        let fullURL = URL(fileURLWithPath: workingCopyPath).appendingPathComponent(item.path)
        if FileManager.default.fileExists(atPath: fullURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fullURL])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workingCopyPath)
        }
    }

    func reloadStatus() {
        run {
            try await self.refreshStatusCore()
            let pending = self.committableWorkingStatuses.count
            self.statusText = "工作副本共 \(self.statuses.count) 项，\(pending) 项待提交"
        }
    }

    func selectWorkingStatus(_ status: WorkingCopyStatus) {
        selectedStatus = status
        showAllDiffLines = false
        workingDiffTask?.cancel()

        if status.isDirectory && !status.kind.isPendingChange {
            workingDiffState = .directory(status.path)
            return
        }

        if !status.kind.isPendingChange && FileIcon.isKnownBinaryExtension(status.path) {
            workingDiffState = .binary(path: status.path, size: nil)
            return
        }

        // 未纳入版本控制的新文件：先检查大小（超过 2 MB 直接按二进制/大文件处理），再读取本地文件内容合成新增预览
        if status.kind == .unversioned {
            let fileURL = URL(fileURLWithPath: workingCopyPath).appendingPathComponent(status.path)
            let maxPreviewBytes: Int64 = 2 * 1024 * 1024
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? (attrs[.size] as? Int64),
               fileSize > maxPreviewBytes {
                workingDiffState = .binary(path: status.path, size: fileSize)
                return
            }
            if let data = try? Data(contentsOf: fileURL) {
                if SVNClient.looksBinaryData(data) {
                    workingDiffState = .binary(path: status.path, size: Int64(data.count))
                } else if let text = SVNClient.decodeText(data) {
                    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    let lines = rawLines.enumerated().map { idx, lineText in
                        FileDiff.Hunk.Line(kind: .addition, text: lineText, oldLine: nil, newLine: idx + 1)
                    }
                    let hunk = FileDiff.Hunk(
                        oldStart: 0,
                        oldCount: 0,
                        newStart: 1,
                        newCount: lines.count,
                        header: "@@ -0,0 +1,\(lines.count) @@ (未版本控制新文件预览)",
                        lines: lines
                    )
                    let diff = FileDiff(
                        id: status.path,
                        path: status.path,
                        localPath: fileURL,
                        isBinary: false,
                        hunks: [hunk]
                    )
                    workingDiffState = .loaded(diff, isTruncated: false)
                } else {
                    workingDiffState = .binary(path: status.path, size: Int64(data.count))
                }
            } else {
                workingDiffState = .idle
            }
            return
        }

        guard status.kind.isPendingChange else {
            workingDiffState = .idle
            return
        }

        workingDiffState = .loading
        workingDiffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let d = try await self.diffCore(forPaths: [status.path])
                guard !Task.isCancelled, self.selectedStatus?.path == status.path else { return }
                if let first = d.first {
                    let selected = d.first(where: { $0.path == status.path }) ?? first
                    self.workingDiffState = .loaded(selected, isTruncated: selected.isTruncated)
                } else {
                    let empty = FileDiff(
                        id: status.path,
                        path: status.path,
                        localPath: URL(fileURLWithPath: self.workingCopyPath).appendingPathComponent(status.path),
                        isBinary: false,
                        hunks: []
                    )
                    self.workingDiffState = .loaded(empty, isTruncated: false)
                }
            } catch {
                guard !Task.isCancelled, self.selectedStatus?.path == status.path else { return }
                let msg = (error as? VCSError)?.errorDescription ?? "\(error)"
                self.workingDiffState = .failed(msg)
            }
        }
    }

    func update() {
        let path = workingCopyPath
        runWorkspaceWrite {
            let r = try await self.updateCore()
            guard self.workingCopyPath == path else { return }
            self.statusText = "已同步到 r\(r.revision)（更新 \(r.updatedCount)，新增 \(r.addedCount)，删除 \(r.deletedCount)）"
            if !self.updateConflicts.isEmpty {
                self.statusText += "，\(self.updateConflicts.count) 处冲突待处理"
                self.sidebarTab = .changes
            }
        }
    }

    func showLog(customPath: String? = nil) {
        run {
            let l = try await self.logCore(customPath: customPath)
            self.statusText = "已加载 \(l.count) 条提交记录"
        }
    }

    func loadMoreLogs() {
        guard !isLoadingMoreLogs else { return }
        guard hasMoreLogs, let lastRev = logs.last?.revision, lastRev > 1 else {
            hasMoreLogs = false
            return
        }
        let targetRepo = repoInfo?.url
        let targetCustomPath = customLogPath
        isLoadingMoreLogs = true
        Task {
            defer { isLoadingMoreLogs = false }
            do {
                let pageSize = 50
                let older = try await self.logCore(
                    customPath: targetCustomPath,
                    limit: pageSize,
                    startRevision: lastRev - 1
                )
                guard self.repoInfo?.url == targetRepo,
                      self.customLogPath == targetCustomPath else {
                    return
                }
                let existingRevs = Set(self.logs.map(\.revision))
                let uniqueOlder = older.filter { !existingRevs.contains($0.revision) }
                self.logs.append(contentsOf: uniqueOlder)
                self.hasMoreLogs = older.count >= pageSize && (self.logs.last?.revision ?? 0) > 1
                self.statusText = "已加载共 \(self.logs.count) 条提交历史"
            } catch {
                guard self.repoInfo?.url == targetRepo,
                      self.customLogPath == targetCustomPath else {
                    return
                }
                let msg = (error as? VCSError)?.errorDescription ?? "\(error)"
                self.errorText = msg
            }
        }
    }

    func commitCheckedChanges() {
        let summary = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            errorText = "请填写提交摘要"
            return
        }
        let desc = commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullMessage = desc.isEmpty ? summary : "\(summary)\n\n\(desc)"

        let selectedItems = statuses.filter { checkedPaths.contains($0.path) }
        guard !selectedItems.isEmpty else {
            errorText = "请至少勾选一个要提交的改动文件"
            return
        }

        if selectedItems.contains(where: { $0.kind == .unversioned && $0.isDirectory }) {
            errorText = "请先将所选目录纳入版本控制，然后审核并选择目录中的文件"
            return
        }
        let conflicts = selectedItems.filter { $0.kind == .conflicted }.map(\.path)
        guard conflicts.isEmpty else {
            errorText = VCSError.conflictsPresent(conflicts).localizedDescription
            return
        }
        if statuses.contains(where: \.mergeInfoChanged),
           statuses.contains(where: { $0.kind.isPendingChange && !checkedPaths.contains($0.path) }) {
            errorText = "检测到合并记录变更，请审核并一并勾选所有待提交的版本化路径"
            return
        }
        let workspace = workingCopyPath
        runWorkspaceWrite {
            guard self.workingCopyPath == workspace else { return }
            // 若勾选了未纳入版本控制的文件，先自动执行 svn add
            let unversionedPaths = selectedItems.filter { $0.kind == .unversioned }.map(\.path)
            if !unversionedPaths.isEmpty {
                let c = try self.clientForWorkingCopy()
                _ = try await c.add(
                    workingCopy: URL(fileURLWithPath: self.workingCopyPath),
                    paths: unversionedPaths
                )
            }
            guard self.workingCopyPath == workspace else { return }
            let targetPaths = selectedItems.map(\.path)
            let r = try await self.commitCore(message: fullMessage, specificPaths: targetPaths)
            guard self.workingCopyPath == workspace else { return }
            _ = try? await self.logCore(customPath: self.customLogPath)
            self.statusText = r.revision > 0
                ? "已提交 r\(r.revision)（共 \(r.committedCount) 项）"
                : "没有可提交的改动"
        }
    }

    func revert(_ item: WorkingCopyStatus) {
        let path = workingCopyPath
        runWorkspaceWrite {
            try await self.revertCore(item)
            if self.workingCopyPath == path { self.statusText = "已回滚 \(item.path)" }
        }
    }

    func add(_ item: WorkingCopyStatus) {
        runWorkspaceWrite {
            try await self.addCore(item)
            self.statusText = "已纳入版本控制 \(item.path)"
        }
    }

    // MARK: - 通用执行器

    private func runWorkspaceWrite(_ body: @escaping () async throws -> Void) {
        guard !isBusy, !workingCopyPath.isEmpty else { return }
        run(body)
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busyCount += 1
        isBusy = busyCount > 0
        errorText = nil
        Task {
            defer {
                busyCount = max(0, busyCount - 1)
                isBusy = busyCount > 0
            }
            do { try await body() }
            catch let e as VCSError { self.errorText = e.errorDescription }
            catch { self.errorText = "\(error)" }
        }
    }

    // MARK: - 命令行自检（与界面共用同一条模型路径，兼容 Tests/run_e2e.sh）

    struct SelfTestCheck {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func selfTest(url: String, workingCopy: String) async -> [SelfTestCheck] {
        var checks: [SelfTestCheck] = []
        let m = AppModel()
        m.isSelfTest = true
        m.repoURLString = url
        m.workingCopyPath = workingCopy

        func step(_ name: String, _ body: () async throws -> String) async {
            do {
                let detail = try await body()
                checks.append(SelfTestCheck(name: name, passed: true, detail: detail))
            } catch {
                checks.append(SelfTestCheck(name: name, passed: false, detail: String(describing: error)))
            }
        }

        await step("连接") {
            let info = try await m.connectCore()
            return "UUID=\(info.uuid ?? "-") 最新修订 r\(info.youngestRevision)，目录 \(m.entries.count) 项"
        }
        await step("浏览子目录") {
            let firstDir = m.entries.first(where: { $0.kind == .directory })?.path
            let items = try await m.browseCore(path: firstDir)
            return "\(firstDir ?? "/") 下 \(items.count) 项"
        }
        if !workingCopy.isEmpty {
            await step("本地状态") {
                try await m.refreshStatusCore()
                let changed = m.statuses.filter { $0.kind.isPendingChange }
                return "共 \(m.statuses.count) 项，其中待处理 \(changed.count) 项"
            }
            await step("差异") {
                let d = try await m.diffCore()
                return "\(d.count) 个文件"
            }
            await step("历史") {
                let l = try await m.logCore()
                return "\(l.count) 条"
            }
        } else {
            await step("远端历史") {
                let l = try await m.logCore()
                return "\(l.count) 条"
            }
        }

        // 附加验证：提交级文件比对（diffFile）与并排配对算法
        await step("提交文件比对") {
            let c = try m.ensureClient()
            let rootURL = m.repoInfo?.rootURL ?? c.repositoryRoot
            // 优先验证首个非二进制源码改动，同时覆盖最新提交改动
            if let textLog = m.logs.first(where: { log in
                UIChangedItem.extract(from: log).contains {
                    !$0.isDirectory && !FileIcon.isKnownBinaryExtension($0.path)
                }
            }),
            let textItem = UIChangedItem.extract(from: textLog).first(where: {
                !$0.isDirectory && !FileIcon.isKnownBinaryExtension($0.path)
            }) {
                let diff = try await c.diffFile(
                    revision: textLog.revision,
                    change: textItem.toChangedPath(),
                    repoRootURL: rootURL
                )
                return "r\(textLog.revision) \(textItem.path)（+\(diff.addedCount) -\(diff.removedCount)，hunks=\(diff.hunks.count)）"
            } else if let anyLog = m.logs.first(where: { log in
                UIChangedItem.extract(from: log).contains(where: { !$0.isDirectory })
            }),
            let anyItem = UIChangedItem.extract(from: anyLog).first(where: { !$0.isDirectory }) {
                let diff = try await c.diffFile(
                    revision: anyLog.revision,
                    change: anyItem.toChangedPath(),
                    repoRootURL: rootURL
                )
                return "r\(anyLog.revision) \(anyItem.path)（+\(diff.addedCount) -\(diff.removedCount)，二进制=\(diff.isBinary)）"
            }
            return "无文件变更记录（跳过）"
        }

        await step("并排差异配对") {
            let sampleHunk = FileDiff.Hunk(
                oldStart: 1, oldCount: 3, newStart: 1, newCount: 4,
                header: "@@ -1,3 +1,4 @@",
                lines: [
                    .init(kind: .deletion, text: "old1", oldLine: 1, newLine: nil),
                    .init(kind: .deletion, text: "old2", oldLine: 2, newLine: nil),
                    .init(kind: .addition, text: "new1", oldLine: nil, newLine: 1),
                    .init(kind: .addition, text: "new2", oldLine: nil, newLine: 2),
                    .init(kind: .addition, text: "new3", oldLine: nil, newLine: 3),
                    .init(kind: .context, text: "ctx", oldLine: 3, newLine: 4),
                ]
            )
            let rows = UISideBySideBuilder.rows(for: sampleHunk)
            guard rows.count == 4, rows[2].left == nil, rows[2].right?.text == "new3" else {
                throw VCSError.underlying("并排配对行数或空侧不符合预期")
            }
            return "2 删 3 增 + 1 上下文 → \(rows.count) 行并排配对通过"
        }

        return checks
    }
}

struct PropertyInspection: Identifiable {
    let id = UUID()
    let target: PropertyTarget
    let isDirectory: Bool

    var isWorkingCopy: Bool {
        if case .workingCopy = target { return true }
        return false
    }
}

struct DirectoryPreview {
    let path: String
    let parents: Bool
    let newPaths: [String]
}

extension AppModel {
    func inspectWorkingProperties(path: String, isDirectory: Bool) {
        guard !workingCopyPath.isEmpty, !isBusy else { return }
        inspectProperties(PropertyInspection(
            target: .workingCopy(root: URL(fileURLWithPath: workingCopyPath), path: path),
            isDirectory: isDirectory))
    }

    func inspectRepositoryProperties(_ entry: RepositoryEntry) {
        guard let base = repoInfo?.url, !isBusy else { return }
        let url = entry.path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        inspectProperties(PropertyInspection(target: .repository(url), isDirectory: entry.kind == .directory))
    }

    private func inspectProperties(_ inspection: PropertyInspection) {
        nodeProperties = []
        nodeIgnoreRules = nil
        propertyFeedback = nil
        propertyName = ""
        propertyValue = ""
        pendingPropertyDeletion = nil
        propertyInspection = inspection
        run { try await self.loadProperties(inspection) }
    }

    private func loadProperties(_ inspection: PropertyInspection) async throws {
        let client: any RepositoryClient
        switch inspection.target {
        case .workingCopy: client = try clientForWorkingCopy()
        case .repository: client = try ensureClient()
        }
        let rows = try await client.properties(at: inspection.target, revision: nil, peg: nil, inherited: true)
        guard propertyInspection?.id == inspection.id else { return }
        nodeProperties = rows
        if case .workingCopy(let root, let path) = inspection.target, inspection.isDirectory {
            let rules = try await client.ignoreRules(workingCopy: root, directory: path)
            guard propertyInspection?.id == inspection.id else { return }
            nodeIgnoreRules = rules
        }
    }

    func changeProperty(_ inspection: PropertyInspection, name: String, text: String?) {
        guard propertyInspection?.id == inspection.id,
              case .workingCopy(let root, let path) = inspection.target,
              root == URL(fileURLWithPath: workingCopyPath) else { return }
        if text != nil, nodeProperties.contains(where: { $0.source == nil && $0.name == name && $0.textValue == nil }) {
            errorText = "二进制属性请通过命令行编辑"
            return
        }
        runWorkspaceWrite {
            guard self.propertyInspection?.id == inspection.id,
                  root == URL(fileURLWithPath: self.workingCopyPath) else { return }
            self.propertyFeedback = nil
            let client: any RepositoryClient = try self.clientForWorkingCopy()
            try await client.setProperty(name, value: text.map { Data($0.utf8) }, workingCopy: root, path: path)
            guard self.propertyInspection?.id == inspection.id else { return }
            let feedback = "属性已\(text == nil ? "删除" : "设置")，待提交"
            self.propertyFeedback = feedback
            self.statusText = feedback
            await self.refreshAfterWrite(path: self.workingCopyPath)
            if let selected = self.selectedStatus, selected.path == path {
                self.selectWorkingStatus(selected)
            }
            do {
                try await self.loadProperties(inspection)
            } catch {
                self.nodeProperties = []
                self.nodeIgnoreRules = nil
                throw VCSError.underlying("属性已修改，重新读取失败：\(error.localizedDescription)")
            }
        }
    }

    var matchingDirectoryPreview: DirectoryPreview? {
        guard let preview = mkdirPreview, preview.path == operationDestination,
              preview.parents == mkdirParents else { return nil }
        return preview
    }

    func previewMkdir(_ operation: WorkspaceOperation) {
        guard case .mkdir = operation.kind, workspaceOperation?.id == operation.id,
              operation.root == workingCopyPath, !isBusy else { return }
        let path = operationDestination
        let parents = mkdirParents
        mkdirPreview = nil
        run {
            guard self.workspaceOperation?.id == operation.id else { return }
            let client: any RepositoryClient = try self.clientForWorkingCopy()
            let paths = try await client.previewDirectory(
                workingCopy: URL(fileURLWithPath: operation.root), path: path, parents: parents)
            guard self.workspaceOperation?.id == operation.id else { return }
            self.mkdirPreview = DirectoryPreview(path: path, parents: parents, newPaths: paths)
        }
    }
}

struct WorkspaceOperation: Identifiable {
    enum Kind {
        case delete, rename, move, copy, resolve(ConflictResolution), merge, mkdir

        var title: String {
            switch self {
            case .delete: return "标记删除"
            case .rename: return "重命名"
            case .move: return "移动"
            case .copy: return "保留历史复制"
            case .resolve(let strategy): return strategy.displayName
            case .merge: return "合并指定修订"
            case .mkdir: return "新建目录"
            }
        }

        var needsDestination: Bool {
            switch self {
            case .rename, .move, .copy, .mkdir: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let root: String
    let path: String
}

extension AppModel {
    func requestWorkspaceOperation(_ kind: WorkspaceOperation.Kind, path: String = "") {
        guard !workingCopyPath.isEmpty, !isBusy else { return }
        operationDestination = ""
        mkdirParents = false
        mkdirPreview = nil
        mergeResult = nil
        mergeError = nil
        workspaceOperation = WorkspaceOperation(kind: kind, root: workingCopyPath, path: path)
    }

    func executeWorkspaceOperation(_ operation: WorkspaceOperation) {
        let input = operationDestination
        let directory = matchingDirectoryPreview
        runWorkspaceWrite {
            guard operation.root == self.workingCopyPath, self.workspaceOperation?.id == operation.id else { return }
            let client: any RepositoryClient = try self.clientForWorkingCopy()
            let wc = URL(fileURLWithPath: operation.root)
            do {
                switch operation.kind {
                case .delete:
                    _ = try await client.delete(workingCopy: wc, paths: [operation.path])
                case .copy:
                    _ = try await client.copy(workingCopy: wc, source: operation.path, destination: input)
                case .move, .rename:
                    let destination: String
                    if case .rename = operation.kind {
                        guard !input.contains("/"), !input.contains("\\") else {
                            throw VCSError.invalidArgument("改名只接受新文件名")
                        }
                        let parent = operation.path.split(separator: "/").dropLast().map(String.init)
                        destination = (parent + [input]).joined(separator: "/")
                    } else {
                        destination = input
                    }
                    _ = try await client.move(workingCopy: wc, source: operation.path, destination: destination)
                case .resolve(let strategy):
                    try await client.resolve(workingCopy: wc, path: operation.path, strategy: strategy)
                case .mkdir:
                    guard let directory else { return }
                    self.mkdirPreview = nil
                    _ = try await client.makeDirectory(workingCopy: wc, path: directory.path,
                                                       parents: directory.parents, expectedCount: directory.newPaths.count)
                case .merge:
                    return
                }
            } catch {
                if self.workingCopyPath == operation.root { try? await self.refreshStatusCore() }
                throw error
            }
            guard self.workingCopyPath == operation.root else { return }
            self.workspaceOperation = nil
            self.statusText = "\(operation.kind.title)完成，仓库尚未提交"
            await self.refreshAfterWrite(path: operation.root)
        }
    }

    var requestedMerge: MergeRequest? {
        guard let url = URL(string: mergeSource.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else { return nil }
        let input = mergeRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let pegText = mergePeg.trimmingCharacters(in: .whitespacesAndNewlines)
        let peg = Int(pegText)
        if !pegText.isEmpty && peg == nil { return nil }
        if let revision = Int(input) {
            return try? MergeRequest(source: url, revision: revision, peg: peg)
        }
        let bounds = input.split(separator: ":", omittingEmptySubsequences: false)
        guard bounds.count == 2, let from = Int(bounds[0]), let to = Int(bounds[1]) else { return nil }
        return try? MergeRequest(source: url, from: from, to: to, peg: peg)
    }

    func executeMerge(_ operation: WorkspaceOperation, dryRun: Bool) {
        guard let request = requestedMerge, operation.root == workingCopyPath else { return }
        if !dryRun {
            guard let preview = mergeResult, preview.dryRun, preview.request == request else { return }
        }
        runWorkspaceWrite {
            guard operation.root == self.workingCopyPath else { return }
            self.mergeError = nil
            self.mergeResult = nil
            do {
                let client: any RepositoryClient = try self.clientForWorkingCopy()
                let result = try await client.merge(workingCopy: URL(fileURLWithPath: operation.root),
                                                    request: request, dryRun: dryRun)
                guard self.workingCopyPath == operation.root else { return }
                self.mergeResult = result
                if !dryRun {
                    self.sidebarTab = .changes
                    self.statusText = result.changedPaths.isEmpty && result.conflictedPaths.isEmpty &&
                        result.skippedPaths.isEmpty && !result.refreshRequired
                        ? "没有可合并的变更" : "合并已应用到工作副本，尚未提交"
                    await self.refreshAfterWrite(path: operation.root)
                }
            } catch {
                guard self.workingCopyPath == operation.root else { return }
                self.mergeError = error.localizedDescription
                if case VCSError.mergeInterrupted = error {
                    self.sidebarTab = .changes
                    try? await self.refreshStatusCore()
                }
            }
        }
    }

    func openConflictFile(_ status: WorkingCopyStatus) {
        guard !status.resolutions.isEmpty else { return }
        let url = URL(fileURLWithPath: workingCopyPath).appendingPathComponent(status.path)
        if !NSWorkspace.shared.open(url) { errorText = "无法打开工作文件" }
    }
}
