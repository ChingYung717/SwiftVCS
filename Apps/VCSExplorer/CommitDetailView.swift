import AppKit
import CVCSKit
import SwiftUI

struct CommitDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let log = model.currentSelectedLog {
            let allChanges = model.currentCommitChanges
            VStack(spacing: 0) {
                // 顶部提交详情头部卡片
                commitHeaderCard(log: log, changes: allChanges)

                Divider()

                // 下方左右分栏：左侧改动文件列表 + 右侧 DiffViewer
                HSplitView {
                    changedFilesSidebar(log: log, allChanges: allChanges)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 380)

                    DiffViewer(
                        filePath: model.selectedChangedItem?.path ?? "",
                        actionBadge: model.selectedChangedItem?.action,
                        state: model.fileDiffState,
                        onRetry: {
                            model.reloadCurrentCommitFileDiff()
                        }
                    )
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyStateView(
                imageName: "select-commit",
                fallbackSymbol: "point.3.connected.trianglepath.dotted",
                title: "选择一次提交查看变更与代码比对",
                subtitle: "在左侧历史列表中点击任意修订记录，即可查看完整提交说明、改动文件列表及并排/统一差异对比。",
                maxImageWidth: 230,
                maxImageHeight: 160
            )
        }
    }

    // MARK: - 提交头部卡片

    private func commitHeaderCard(log: LogEntry, changes: [UIChangedItem]) -> some View {
        let trimmedMsg = log.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmedMsg.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let titleLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "（无提交说明）"
        let bodyLines: String = {
            guard let firstIdx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  firstIdx + 1 < lines.count else { return "" }
            return lines[(firstIdx + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        let addedFiles = changes.filter { $0.action == "A" }.count
        let modifiedFiles = changes.filter { $0.action == "M" }.count
        let deletedFiles = changes.filter { $0.action == "D" }.count
        let replacedFiles = changes.filter { $0.action == "R" }.count

        return VStack(alignment: .leading, spacing: 10) {
            // 第一行：提交主标题与详细描述
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: titleLine)
                    .font(.system(size: 16, weight: .bold))
                    .italic(trimmedMsg.isEmpty)
                    .foregroundStyle(trimmedMsg.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)

                if !bodyLines.isEmpty {
                    ScrollView {
                        Text(verbatim: bodyLines)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 68)
                }
            }

            // 第二行：作者头像、姓名、时间、修订号一键复制、改动统计徽章
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    AvatarView(name: log.author, size: 24)
                    Text(verbatim: log.author.isEmpty ? "未知作者" : log.author)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text(verbatim: "提交于 \(RelativeTime.fullFormat(log.date))（\(RelativeTime.format(log.date, relativeTo: model.now))）")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)

                // 修订号胶囊 + 一键复制按钮
                HStack(spacing: 4) {
                    Text(verbatim: "r\(log.revision)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.brandBlue)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("r\(log.revision)", forType: .string)
                        model.statusText = "已复制修订号 r\(log.revision)"
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.brandBlue)
                    }
                    .buttonStyle(.plain)
                    .help(String("复制修订号 r\(log.revision)"))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Theme.brandBlue.opacity(0.12))
                )

                Spacer()

                // 变更统计徽章
                HStack(spacing: 6) {
                    Text(verbatim: "\(changes.count) 个文件变更")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                        )

                    if addedFiles > 0 {
                        statPill(label: "A", count: addedFiles, color: Theme.actionColor("A"))
                    }
                    if modifiedFiles > 0 {
                        statPill(label: "M", count: modifiedFiles, color: Theme.actionColor("M"))
                    }
                    if deletedFiles > 0 {
                        statPill(label: "D", count: deletedFiles, color: Theme.actionColor("D"))
                    }
                    if replacedFiles > 0 {
                        statPill(label: "R", count: replacedFiles, color: Theme.actionColor("R"))
                    }

                    if case .loaded(let diff, _) = model.fileDiffState, !diff.isBinary {
                        HStack(spacing: 4) {
                            Text(verbatim: "+\(diff.addedCount)")
                                .foregroundStyle(Theme.addFG)
                            Text(verbatim: "−\(diff.removedCount)")
                                .foregroundStyle(Theme.delFG)
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statPill(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Text(verbatim: "\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.13))
        )
    }

    // MARK: - 左侧涉及文件列表

    private func changedFilesSidebar(log: LogEntry, allChanges: [UIChangedItem]) -> some View {
        let filtered: [UIChangedItem] = {
            let q = model.commitFileFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return allChanges }
            return allChanges.filter { $0.path.localizedCaseInsensitiveContains(q) }
        }()

        return VStack(spacing: 0) {
            // 标题与过滤框
            VStack(spacing: 6) {
                HStack {
                    Text(verbatim: "涉及文件 (\(allChanges.count))")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if allChanges.count > 4 {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("过滤此提交中的文件…", text: $model.commitFileFilterQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !model.commitFileFilterQuery.isEmpty {
                            Button {
                                model.commitFileFilterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.02))

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(allChanges.isEmpty ? "此提交未记录路径变更" : "未找到匹配的文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { item in
                            let isSelected = model.selectedChangedItem?.path == item.path
                            ChangedFileRowView(
                                item: item,
                                isSelected: isSelected
                            ) {
                                model.selectChangedItem(item)
                            }
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ChangedFileRowView: View {
    @EnvironmentObject private var model: AppModel
    let item: UIChangedItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let icon = FileIcon.symbol(for: item.path, isDirectory: item.isDirectory)
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ActionBadgeView(action: item.action, isSelected: isSelected)

                Image(systemName: icon.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : icon.color)
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(verbatim: item.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .italic(item.isDirectory)
                            .foregroundStyle(isSelected ? .white : (item.isDirectory ? .secondary : .primary))
                            .lineLimit(1)

                        if item.isDirectory {
                            HStack(spacing: 2.5) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("目录")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(isSelected ? .white.opacity(0.92) : .secondary)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.22) : Color.secondary.opacity(0.14))
                            )
                        }
                    }

                    Text(verbatim: item.directoryPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let copyFrom = item.copyFromPath {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                            Text(verbatim: "复制自 \(copyFrom)\(item.copyFromRevision.map { "@r\($0)" } ?? "")")
                                .font(.system(size: 9.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.brandBlue)
                    }
                }

                Spacer(minLength: 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? AnyShapeStyle(Theme.brandBlue)
                    : AnyShapeStyle(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.path)
        .contextMenu {
            Button("复制文件路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
                model.statusText = "已复制 \(item.path)"
            }
            Button("查看此路径的提交历史") {
                model.showLogForPath(item.path)
            }
        }
    }
}
