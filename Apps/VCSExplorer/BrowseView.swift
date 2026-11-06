import AppKit
import CVCSKit
import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var model: AppModel

    private struct BreadcrumbSegment: Identifiable {
        let id: String
        let title: String
        let path: String?
    }

    private var breadcrumbs: [BreadcrumbSegment] {
        var result: [BreadcrumbSegment] = [
            BreadcrumbSegment(id: "__root__", title: "/", path: nil)
        ]
        let parts = model.currentPath.split(separator: "/").map(String.init)
        var accumulated = ""
        for part in parts {
            accumulated = accumulated.isEmpty ? part : "\(accumulated)/\(part)"
            result.append(BreadcrumbSegment(id: accumulated, title: part, path: accumulated))
        }
        return result
    }

    private var filteredEntries: [RepositoryEntry] {
        let q = model.browseSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            ($0.author?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部层级面包屑导航条
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Button {
                        model.goUp()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.currentPath.isEmpty)
                    .help("返回上级目录")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { idx, seg in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                let isLast = idx == breadcrumbs.count - 1
                                Button {
                                    model.browse(path: seg.path)
                                } label: {
                                    HStack(spacing: 3) {
                                        if idx == 0 {
                                            Image(systemName: "house.fill")
                                                .font(.system(size: 10))
                                        }
                                        Text(seg.title)
                                            .font(.system(size: 11.5, weight: isLast ? .semibold : .regular, design: .monospaced))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(isLast ? Theme.brandBlue.opacity(0.14) : Color.primary.opacity(0.04))
                                    )
                                    .foregroundStyle(isLast ? Theme.brandBlue : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        model.browse(path: model.currentPath.isEmpty ? nil : model.currentPath)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.repoInfo == nil)
                    .help("刷新当前目录")
                }

                // 目录内过滤搜索框
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("过滤当前目录文件或作者…", text: $model.browseSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !model.browseSearchQuery.isEmpty {
                        Button {
                            model.browseSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding(8)
            .background(Color.primary.opacity(0.02))

            Divider()

            if model.repoInfo == nil && model.entries.isEmpty {
                EmptyStateView(
                    imageName: "welcome",
                    fallbackSymbol: "externaldrive",
                    title: "尚未连接远端仓库",
                    subtitle: "连接 SVN 仓库后即可在线浏览目录树、预览代码文件或检出子模块。",
                    maxImageWidth: 160,
                    maxImageHeight: 110
                ) {
                    Button("连接仓库…") {
                        model.showConnectSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if filteredEntries.isEmpty {
                EmptyStateView(
                    fallbackSymbol: "folder",
                    title: model.entries.isEmpty ? "此目录为空" : "无匹配条目",
                    subtitle: model.entries.isEmpty ? "当前仓库路径下没有子目录或文件。" : "未找到包含「\(model.browseSearchQuery)」的文件。",
                    maxImageWidth: 120,
                    maxImageHeight: 90
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            let isSelected = model.selectedEntry?.id == entry.id
                            BrowseEntryRowView(
                                entry: entry,
                                isSelected: isSelected,
                                onSelect: {
                                    model.selectBrowseEntry(entry)
                                },
                                onOpenDirectory: {
                                    model.open(entry)
                                }
                            )
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }
}

private struct BrowseEntryRowView: View {
    @EnvironmentObject private var model: AppModel
    let entry: RepositoryEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenDirectory: () -> Void

    var body: some View {
        let icon = FileIcon.symbol(for: entry.name, isDirectory: entry.kind == .directory)
        HStack(spacing: 9) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 13.5))
                        .foregroundStyle(isSelected ? .white : icon.color)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(verbatim: entry.name)
                            .font(.system(size: 13, weight: entry.kind == .directory ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(verbatim: "r\(entry.revision)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            if let author = entry.author, !author.isEmpty {
                                Text("·")
                                Text(verbatim: author)
                            }
                            if let date = entry.lastModified {
                                Text("·")
                                Text(verbatim: RelativeTime.format(date, relativeTo: model.now))
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.84) : .secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if entry.kind != .directory, let size = entry.size, size >= 0 {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if entry.kind == .directory {
                Button {
                    onOpenDirectory()
                } label: {
                    HStack(spacing: 2) {
                        Text("进入")
                            .font(.system(size: 10))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(isSelected ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .help(String("进入子目录 \(entry.name)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? AnyShapeStyle(Theme.brandBlue)
                : AnyShapeStyle(Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            if entry.kind == .directory {
                Button("进入此目录") {
                    model.open(entry)
                }
                Button("检出此目录到指定位置…") {
                    model.checkoutWithPanel(entry: entry)
                }
                Button("快速检出到临时目录") {
                    model.checkout(entry: entry)
                }
            } else {
                Button("在线预览文件内容") {
                    model.previewEntry(entry)
                }
                Button("检出所在目录到指定位置…") {
                    model.checkoutWithPanel(entry: entry)
                }
            }
            Divider()
            Button("查看此路径的提交历史") {
                model.showLogForEntry(entry)
            }
            Button("复制仓库内路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("/\(entry.path)", forType: .string)
                model.statusText = "已复制 /\(entry.path)"
            }
        }
    }
}
