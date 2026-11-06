import AppKit
import CVCSKit
import SwiftUI

struct ChangesListView: View {
    @EnvironmentObject private var model: AppModel

    private var displayedStatuses: [WorkingCopyStatus] {
        model.displayedWorkingStatuses
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部全选与状态过滤栏
            HStack(spacing: 8) {
                if !model.workingCopyPath.isEmpty && !model.committableWorkingStatuses.isEmpty {
                    Toggle("", isOn: Binding(
                        get: { model.areAllChangesChecked },
                        set: { model.setAllChangesChecked($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("全选 / 取消全选待提交文件")
                }

                Text(verbatim: model.showAllStatuses ? "\(displayedStatuses.count) 个条目" : "\(displayedStatuses.count) 个变更项")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("含正常项", isOn: $model.showAllStatuses)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    model.reloadStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(model.workingCopyPath.isEmpty)
                .help("刷新本地工作副本状态")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.02))

            Divider()

            // 中间变更文件列表
            if !model.updateConflicts.isEmpty {
                Text(verbatim: "有 \(model.updateConflicts.count) 处冲突待处理")
                    .font(.caption)
                    .foregroundStyle(Theme.statusColor(.conflicted))
                    .padding(.vertical, 4)
            }

            if model.workingCopyPath.isEmpty {
                EmptyStateView(
                    imageName: "no-changes",
                    fallbackSymbol: "folder.badge.plus",
                    title: "尚未绑定本地工作副本",
                    subtitle: "您可以打开已有的本地 .svn 工作副本目录，或从当前远端仓库检出（Checkout）到本地。",
                    maxImageWidth: 165,
                    maxImageHeight: 115
                ) {
                    HStack(spacing: 8) {
                        Button("选择工作副本…") {
                            model.chooseWorkingCopyDirectory()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if model.repoInfo != nil {
                            Button("从仓库检出…") {
                                model.checkoutWithPanel(entry: model.selectedEntry)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } else if displayedStatuses.isEmpty {
                EmptyStateView(
                    imageName: "no-changes",
                    fallbackSymbol: "checkmark.circle.fill",
                    title: "工作副本干净",
                    subtitle: "当前工作副本中没有未提交的本地更改（共扫描 \(model.statuses.count) 个条目）。",
                    maxImageWidth: 165,
                    maxImageHeight: 115
                ) {
                    HStack(spacing: 8) {
                        Button("刷新状态") {
                            model.reloadStatus()
                        }
                        .controlSize(.small)

                        Button("SVN Update 同步") {
                            model.update()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedStatuses) { status in
                            let isSelected = model.selectedStatus?.path == status.path
                            WorkingChangeRowView(
                                status: status,
                                isSelected: isSelected,
                                isChecked: model.bindingForCheckedPath(status.path),
                                onSelect: {
                                    model.selectWorkingStatus(status)
                                },
                                onRequestRevert: {
                                    model.pendingRevertStatus = status
                                }
                            )
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }

            // 底部 GitHub Desktop 风格提交面板
            if !model.workingCopyPath.isEmpty {
                Divider()
                commitBox
            }
        }
        .alert(
            "确认放弃本地更改？",
            isPresented: Binding(
                get: { model.pendingRevertStatus != nil },
                set: { if !$0 { model.pendingRevertStatus = nil } }
            ),
            presenting: model.pendingRevertStatus
        ) { item in
            Button("取消", role: .cancel) {
                model.pendingRevertStatus = nil
            }
            Button("放弃更改 (Revert)", role: .destructive) {
                model.revert(item)
                model.pendingRevertStatus = nil
            }
        } message: { item in
            let paths = model.pairedPaths(for: item.path).sorted().joined(separator: "、")
            Text(verbatim: "将放弃所列路径的版本化改动：\(paths)。目录项只处理自身。若移动目标含本地改动，会拒绝操作以保护文件内容。")
        }
    }

    // MARK: - GitHub Desktop 风格底部提交框

    private var commitBox: some View {
        let checkedCount = model.checkedPaths.count
        let canCommit = checkedCount > 0 &&
            !model.commitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isBusy

        return VStack(alignment: .leading, spacing: 8) {
            // 第一行：作者头像 + 必填摘要输入框
            HStack(spacing: 8) {
                AvatarView(
                    name: model.username.isEmpty ? NSUserName() : model.username,
                    size: 24
                )
                TextField("提交摘要（必填）", text: $model.commitSummary)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            // 第二行：详细描述多行输入框
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

                if model.commitDescription.isEmpty {
                    Text("详细描述（可选）…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $model.commitDescription)
                    .font(.system(size: 11.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 62)

            // 第三行：醒目的「提交到仓库」主按钮
            Button {
                model.commitCheckedChanges()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 13))
                    Text(verbatim: checkedCount > 0
                         ? "提交到仓库（\(checkedCount) 个文件）"
                         : "请勾选要提交的文件")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(canCommit ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.18)))
                )
                .foregroundStyle(canCommit ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .keyboardShortcut(.return, modifiers: .command)
            .help("将勾选的改动文件提交到 SVN 仓库 (⌘↩)")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct WorkingChangeRowView: View {
    @EnvironmentObject private var model: AppModel
    let status: WorkingCopyStatus
    let isSelected: Bool
    @Binding var isChecked: Bool
    let onSelect: () -> Void
    let onRequestRevert: () -> Void

    private var parentDir: String {
        guard let idx = status.path.lastIndex(of: "/"), idx > status.path.startIndex else {
            return ""
        }
        return String(status.path[status.path.startIndex..<idx])
    }

    private var rowDetail: String {
        if status.kind == .conflicted {
            let names = status.conflictKinds.map(\.displayName).sorted().joined(separator: "、")
            return names.isEmpty ? "冲突" : "\(names)冲突"
        }
        if status.mergeInfoChanged { return "svn:mergeinfo" }
        if let path = status.movedTo { return "→ \(path)" }
        if let path = status.movedFrom { return "← \(path)" }
        return ""
    }

    var body: some View {
        let icon = FileIcon.symbol(for: status.path, isDirectory: status.isDirectory)
        let isCommittable = status.kind != .normal && status.kind != .ignored
        HStack(spacing: 8) {
            if isCommittable {
                Toggle("", isOn: $isChecked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Spacer()
                    .frame(width: 14)
            }

            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .white : icon.color)
                        .frame(width: 15)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: status.name.isEmpty ? status.path : status.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)
                        if !parentDir.isEmpty {
                            Text(verbatim: parentDir)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !rowDetail.isEmpty {
                            Text(verbatim: rowDetail)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? .white : Theme.statusColor(status.kind))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(rowDetail)
                        }
                        if let owner = status.lockOwner, !owner.isEmpty {
                            Label {
                                Text(verbatim: "锁持有者：\(owner)")
                            } icon: {
                                Image(systemName: "lock.fill")
                            }
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Text(verbatim: "锁持有者：\(owner)"))
                        }
                    }

                    Spacer(minLength: 4)

                    WCStatusBadgeView(kind: status.kind, isSelected: isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? AnyShapeStyle(Theme.brandBlue)
                : AnyShapeStyle(Color.clear)
        )
        .contextMenu {
            if [.normal, .modified, .added, .replaced].contains(status.kind) {
                Button("节点属性…") {
                    model.inspectWorkingProperties(path: status.path, isDirectory: status.isDirectory)
                }
                .disabled(model.isBusy)
            }
            if status.kind == .conflicted {
                ConflictActions(status: status)
            }
            if !status.isDirectory && [.normal, .modified, .added, .replaced].contains(status.kind) {
                if status.kind == .normal {
                    Button("标记删除…", role: .destructive) {
                        model.requestWorkspaceOperation(.delete, path: status.path)
                    }
                    .disabled(model.isBusy)
                    .help("删除本地文件，仓库在提交后更新")
                }
                Button("重命名…") { model.requestWorkspaceOperation(.rename, path: status.path) }
                    .disabled(model.isBusy).help("同目录改名")
                Button("移动…") { model.requestWorkspaceOperation(.move, path: status.path) }
                    .disabled(model.isBusy).help("移动到工作副本内的目标")
                Button("保留历史复制…") { model.requestWorkspaceOperation(.copy, path: status.path) }
                    .disabled(model.isBusy).help("复制到工作副本内的目标并保留来源历史")
            }

            if status.kind.isPendingChange {
                Button("查看差异") {
                    model.selectWorkingStatus(status)
                }
                Button("放弃更改 / 回滚 (Revert)…", role: .destructive) {
                    onRequestRevert()
                }
            }
            if status.kind == .unversioned {
                Button("纳入版本控制 (svn add)") {
                    model.add(status)
                }
            }
            Divider()
            Button("在 Finder 中显示") {
                model.revealStatusItemInFinder(status)
            }
            Button("复制相对路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(status.path, forType: .string)
                model.statusText = "已复制路径 \(status.path)"
            }
        }
    }
}
