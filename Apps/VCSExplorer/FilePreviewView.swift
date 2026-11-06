import AppKit
import CVCSKit
import SwiftUI

struct FilePreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let entry = model.selectedEntry {
            VStack(spacing: 0) {
                // 顶部元信息卡片
                entryHeaderCard(entry)

                Divider()

                // 主体区域：目录概览 或 文件带行号代码预览
                if entry.kind == .directory {
                    directoryBody(entry)
                } else {
                    filePreviewBody(entry)
                }
            }
        } else {
            EmptyStateView(
                imageName: "welcome",
                fallbackSymbol: "doc.text.magnifyingglass",
                title: "选择仓库条目查看详情或在线预览",
                subtitle: "在左侧「浏览」列表中点击任意文件即可在线预览代码，点击目录可查看详情或进入下级路径。",
                maxImageWidth: 210,
                maxImageHeight: 145
            )
        }
    }

    // MARK: - 顶部元信息卡片

    private func entryHeaderCard(_ entry: RepositoryEntry) -> some View {
        let icon = FileIcon.symbol(for: entry.name, isDirectory: entry.kind == .directory)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(icon.color.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(icon.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.name)
                            .font(.system(size: 14.5, weight: .bold))
                        Text(entry.kind == .directory ? "目录" : "文件")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }

                    HStack(spacing: 5) {
                        Text(verbatim: "/\(entry.path)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("/\(entry.path)", forType: .string)
                            model.statusText = "已复制路径 /\(entry.path)"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制仓库路径")
                    }
                }

                Spacer()

                // 操作按钮组
                HStack(spacing: 8) {
                    if entry.kind == .directory {
                        Button {
                            model.open(entry)
                        } label: {
                            Label("进入目录", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button {
                            model.previewEntry(entry)
                        } label: {
                            Label("刷新预览", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        model.checkoutWithPanel(entry: entry)
                    } label: {
                        Label("检出到…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        model.showLogForEntry(entry)
                    } label: {
                        Label("查看提交历史", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // 第二行：版本与作者元信息
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Text("最后修改修订：")
                        .foregroundStyle(.secondary)
                    Text(verbatim: "r\(entry.revision)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.brandBlue)
                }

                if let author = entry.author, !author.isEmpty {
                    HStack(spacing: 5) {
                        AvatarView(name: author, size: 18)
                        Text(author)
                            .fontWeight(.medium)
                    }
                }

                if let date = entry.lastModified {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(RelativeTime.fullFormat(date))（\(RelativeTime.format(date, relativeTo: model.now))）")
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.kind != .directory, let size = entry.size, size >= 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 目录详情体

    private func directoryBody(_ entry: RepositoryEntry) -> some View {
        EmptyStateView(
            fallbackSymbol: "folder.fill",
            title: "远端目录：\(entry.name)",
            subtitle: "您可以进入该子目录继续浏览文件，将该目录检出（Checkout）到本地工作副本，或查看该目录的完整提交历史。",
            maxImageWidth: 130,
            maxImageHeight: 95
        ) {
            HStack(spacing: 10) {
                Button {
                    model.open(entry)
                } label: {
                    Label("进入此目录", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.checkoutWithPanel(entry: entry)
                } label: {
                    Label("检出到本地…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    model.showLogForEntry(entry)
                } label: {
                    Label("查看此目录历史", systemImage: "clock")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 文件带行号预览体

    private static func splitPreviewLines(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [""] }
        let normalized = raw.utf8.contains(0x0D)
            ? raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : raw
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if normalized.hasSuffix("\n"), lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    @ViewBuilder
    private func filePreviewBody(_ entry: RepositoryEntry) -> some View {
        if model.isPreviewLoading && (model.previewTitle == entry.path || model.previewText == nil) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(verbatim: "正在读取 \(entry.name) 的内容…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else if model.previewTitle == entry.path, let text = model.previewText {
            if model.isPreviewBinary {
                EmptyStateView(
                    fallbackSymbol: FileIcon.symbol(for: entry.name).symbol,
                    title: text.hasPrefix("读取文件预览失败") ? "无法读取文件预览" : "二进制或超大文件",
                    subtitle: text,
                    maxImageWidth: 130,
                    maxImageHeight: 95
                ) {
                    HStack(spacing: 8) {
                        if text.hasPrefix("读取文件预览失败") {
                            Button {
                                model.previewEntry(entry)
                            } label: {
                                Label("重试预览", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Button {
                            model.showLogForEntry(entry)
                        } label: {
                            Label("查看此文件历史与修订记录", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                let allLines = Self.splitPreviewLines(text)
                let limit = model.showAllPreviewLines ? allLines.count : min(allLines.count, 3000)

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<limit, id: \.self) { idx in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(verbatim: "\(idx + 1)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .trailing)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.025))

                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: 1)

                                let rawLine = allLines[idx]
                                let expanded = rawLine.contains("\t") ? rawLine.replacingOccurrences(of: "\t", with: "    ") : rawLine
                                let safeLine = expanded.isEmpty ? " " : (expanded.count > 1200 ? String(expanded.prefix(1200)) + " …" : expanded)
                                Text(verbatim: safeLine)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(.leading, 10)
                                    .padding(.trailing, 16)
                                    .padding(.vertical, 1.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if allLines.count > 3000 && !model.showAllPreviewLines {
                            HStack(spacing: 10) {
                                Text(verbatim: "已显示前 3000 行（共 \(allLines.count) 行）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(String("显示全部 \(allLines.count) 行")) {
                                    model.showAllPreviewLines = true
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(12)
                        }
                    }
                    .frame(minWidth: 720, maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(verbatim: "正在读取 \(entry.name) 的内容…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
