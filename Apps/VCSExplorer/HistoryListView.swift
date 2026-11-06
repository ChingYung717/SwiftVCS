import AppKit
import CVCSKit
import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject private var model: AppModel

    private var filteredLogs: [LogEntry] {
        let q = model.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.logs }
        let normalizedRev = q.lowercased().hasPrefix("r") ? String(q.dropFirst()) : q
        return model.logs.filter { log in
            if "r\(log.revision)".localizedCaseInsensitiveContains(q) ||
               "\(log.revision)".contains(normalizedRev) {
                return true
            }
            if log.author.localizedCaseInsensitiveContains(q) {
                return true
            }
            if log.message.localizedCaseInsensitiveContains(q) {
                return true
            }
            if log.changedPaths.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部搜索与刷新栏
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField("搜索修订号(r8350)、作者、说明或文件…", text: $model.historySearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !model.historySearchQuery.isEmpty {
                            Button {
                                model.historySearchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )

                    Button {
                        model.showLog(customPath: model.customLogPath)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.repoInfo == nil && model.workingCopyPath.isEmpty)
                    .help("刷新提交历史")
                }

                // 若当前按指定路径过滤历史，展示可关闭的过滤提示条
                if let customPath = model.customLogPath, !customPath.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(Theme.brandBlue)
                            .font(.system(size: 11))
                        Text(verbatim: "路径：/\(customPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.customLogPath = nil
                            model.showLog(customPath: nil)
                        } label: {
                            HStack(spacing: 2) {
                                Text("全部历史")
                                Image(systemName: "xmark")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.brandBlue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.brandBlue.opacity(0.10))
                    )
                }
            }
            .padding(8)

            Divider()

            if model.logs.isEmpty {
                EmptyStateView(
                    imageName: "select-commit",
                    fallbackSymbol: "clock.arrow.circlepath",
                    title: model.isBusy ? "正在加载提交历史…" : "暂无提交历史",
                    subtitle: model.isBusy
                        ? "正在从 SVN 仓库读取最近修订记录"
                        : "连接仓库或打开工作副本后即可浏览每次提交及文件比对",
                    maxImageWidth: 160,
                    maxImageHeight: 110
                ) {
                    if !model.isBusy && (model.repoInfo != nil || !model.workingCopyPath.isEmpty) {
                        Button("读取提交历史") {
                            model.showLog()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } else if filteredLogs.isEmpty {
                EmptyStateView(
                    fallbackSymbol: "magnifyingglass",
                    title: "无匹配的提交记录",
                    subtitle: "未找到包含「\(model.historySearchQuery)」的修订，请尝试其它关键词或加载更多历史",
                    maxImageWidth: 120,
                    maxImageHeight: 90
                ) {
                    HStack(spacing: 8) {
                        Button("清除搜索") {
                            model.historySearchQuery = ""
                        }
                        .controlSize(.small)
                        if model.hasMoreLogs {
                            Button("加载更多历史") {
                                model.loadMoreLogs()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredLogs) { log in
                            let isSelected = model.selectedRevision == log.revision
                            HistoryRowView(
                                log: log,
                                isSelected: isSelected
                            ) {
                                model.selectRevision(log.revision)
                            }
                            .id(log.revision)

                            Divider()
                                .padding(.leading, 48)
                        }

                        // 底部分页加载更多栏
                        HStack {
                            Spacer()
                            if model.isLoadingMoreLogs {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在加载更早的提交…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                            } else if model.hasMoreLogs {
                                Button {
                                    model.loadMoreLogs()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.down.circle")
                                        Text(verbatim: "加载更多历史（当前已加载 \(model.logs.count) 条）")
                                    }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Theme.brandBlue)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    model.loadMoreLogs()
                                }
                            } else {
                                Text(verbatim: "已加载全部 \(model.logs.count) 条修订")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 10)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRowView: View {
    @EnvironmentObject private var model: AppModel
    let log: LogEntry
    let isSelected: Bool
    let onSelect: () -> Void

    private var summaryLine: (text: String, isEmpty: Bool) {
        let first = log.message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let first, !first.isEmpty {
            return (first, false)
        }
        return ("（无提交说明）", true)
    }

    var body: some View {
        let summary = summaryLine
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(name: log.author, size: 30)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.text)
                            .font(.system(size: 13, weight: summary.isEmpty ? .regular : .semibold))
                            .italic(summary.isEmpty)
                            .foregroundStyle(
                                isSelected
                                    ? .white
                                    : (summary.isEmpty ? .secondary : .primary)
                            )
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(verbatim: "r\(log.revision)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? .white : Theme.brandBlue)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.22) : Theme.brandBlue.opacity(0.12))
                            )
                    }

                    HStack(spacing: 5) {
                        Text(verbatim: log.author.isEmpty ? "未知作者" : log.author)
                            .font(.system(size: 11.5, weight: .medium))
                        Text("·")
                        Text(verbatim: RelativeTime.format(log.date, relativeTo: model.now))
                            .font(.system(size: 11.5))
                        if !log.changedPaths.isEmpty {
                            Text("·")
                            Text(verbatim: "\(log.changedPaths.count) 个文件")
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white.opacity(0.86) : .secondary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? AnyShapeStyle(Theme.brandBlue)
                    : AnyShapeStyle(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String("复制修订号 r\(log.revision)")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("r\(log.revision)", forType: .string)
                model.statusText = "已复制 r\(log.revision)"
            }
            Button("复制提交说明") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.message, forType: .string)
                model.statusText = "已复制提交说明"
            }
            if !log.changedPaths.isEmpty {
                Button(String("复制涉及文件列表（\(log.changedPaths.count) 项）")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.changedPaths.joined(separator: "\n"), forType: .string)
                    model.statusText = "已复制涉及文件列表"
                }
                if model.repoInfo != nil {
                    Divider()
                    Button("浏览该提交所在的仓库目录") {
                        model.browseDirectoryOfCommit(log)
                    }
                }
            }
        }
    }
}
