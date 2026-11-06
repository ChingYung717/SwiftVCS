import CSVNKit
import AppKit
import Combine
import SwiftUI

struct RepoToolbar: View {
    @EnvironmentObject private var model: AppModel

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var repoDisplayName: String {
        if let info = model.repoInfo {
            let last = info.url.lastPathComponent
            return last.isEmpty || last == "/" ? (info.url.host ?? info.url.absoluteString) : last
        }
        let trimmed = model.repoURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            let last = url.lastPathComponent
            if !last.isEmpty && last != "/" { return last }
            if let host = url.host { return host }
        }
        return trimmed.isEmpty ? "未连接仓库" : trimmed
    }

    private var repoSubtitle: String {
        if let info = model.repoInfo {
            return info.url.absoluteString
        }
        if !model.repoURLString.isEmpty {
            return model.repoURLString
        }
        return "点击配置 SVN 仓库地址与证书"
    }

    private var workingCopyOrPathTitle: String {
        if !model.workingCopyPath.isEmpty {
            return "本地工作副本"
        }
        return "当前浏览路径"
    }

    private var workingCopyOrPathValue: String {
        if !model.workingCopyPath.isEmpty {
            let name = URL(fileURLWithPath: model.workingCopyPath).lastPathComponent
            return name.isEmpty ? model.workingCopyPath : name
        }
        if model.repoInfo != nil {
            return model.currentPath.isEmpty ? "/ (根目录)" : "/\(model.currentPath)"
        }
        return "未选择工作副本"
    }

    private var refreshSubtitle: String {
        if model.isBusy {
            return model.statusText.isEmpty ? "正在执行操作…" : model.statusText
        }
        if let last = model.lastRefresh {
            return "上次刷新：\(RelativeTime.format(last, relativeTo: model.now))"
        }
        return "点击拉取最新历史与状态"
    }

    var body: some View {
        HStack(spacing: 0) {
            // ① 当前仓库段（使用 plain Button + Popover，避免 macOS NSPopUpButton 吞掉多行标题与字号）
            Button {
                model.showRepoPopover.toggle()
            } label: {
                ToolbarSegmentCell(
                    icon: model.repoInfo != nil ? "server.rack" : "externaldrive.badge.questionmark",
                    iconColor: model.repoInfo != nil ? Theme.brandBlue : .secondary,
                    label: "当前仓库",
                    value: repoDisplayName,
                    showChevron: true,
                    isActive: model.showRepoPopover
                )
            }
            .buttonStyle(.plain)
            .frame(minWidth: 230, maxWidth: 320)
            .help(repoSubtitle)
            .popover(isPresented: $model.showRepoPopover, arrowEdge: .bottom) {
                repoMenuPopover
            }

            Divider()
                .frame(height: 36)

            // ② 当前浏览路径 / 本地工作副本段
            Button {
                model.showWorkspacePopover.toggle()
            } label: {
                ToolbarSegmentCell(
                    icon: model.workingCopyPath.isEmpty ? "point.topleft.down.curvedto.point.bottomright.up" : "folder.fill",
                    iconColor: model.workingCopyPath.isEmpty ? .purple : .orange,
                    label: workingCopyOrPathTitle,
                    value: workingCopyOrPathValue,
                    showChevron: true,
                    isActive: model.showWorkspacePopover
                )
            }
            .buttonStyle(.plain)
            .frame(minWidth: 220, maxWidth: 300)
            .help(model.workingCopyPath.isEmpty ? "管理本地工作副本或检出仓库" : model.workingCopyPath)
            .popover(isPresented: $model.showWorkspacePopover, arrowEdge: .bottom) {
                workspaceMenuPopover
            }

            Divider()
                .frame(height: 36)

            // ③ 同步 / 刷新按钮段
            Button {
                model.refreshAll()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.brandBlue.opacity(0.12))
                            .frame(width: 32, height: 32)
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Theme.brandBlue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.workingCopyPath.isEmpty ? "刷新仓库" : "刷新状态与历史")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            if let info = model.repoInfo {
                                Text(verbatim: "r\(info.youngestRevision)")
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.brandBlue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule()
                                            .fill(Theme.brandBlue.opacity(0.14))
                                    )
                            }
                        }
                        Text(refreshSubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.repoInfo == nil && model.workingCopyPath.isEmpty && model.repoURLString.isEmpty)
            .frame(minWidth: 210, maxWidth: 280)
            .help("刷新当前仓库历史、目录与本地工作副本状态 (⌘R)")

            if !model.workingCopyPath.isEmpty {
                Button {
                    model.update()
                } label: {
                    Label("SVN Update", systemImage: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.trailing, 8)
                .help("从远端拉取最新变更到本地工作副本")
            }

            Spacer()

            // 右侧快捷状态与连接设置按钮
            HStack(spacing: 10) {
                if let host = URL(string: model.repoURLString).flatMap(SVNOrigin.init)?.endpoint,
                   model.trustedHosts.contains(host) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(host)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.10))
                    )
                    .help(String("已信任 \(host) 的 TLS 证书"))
                }

                Button {
                    model.showConnectSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.repoInfo == nil ? "link.badge.plus" : "slider.horizontal.3")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(model.repoInfo == nil ? "连接仓库…" : "连接设置")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(model.repoInfo == nil ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                    )
                    .foregroundStyle(model.repoInfo == nil ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help("打开仓库连接与自签名证书配置弹窗 (⌘⇧N)")
            }
            .padding(.trailing, 14)
        }
        .frame(height: 58)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onReceive(timer) { date in
            model.now = date
        }
    }

    // MARK: - 仓库下拉弹窗

    private var repoMenuPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = model.repoInfo {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已连接仓库")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(info.url.absoluteString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(verbatim: "最新修订 r\(info.youngestRevision) · UUID \(info.uuid?.prefix(8) ?? "-")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()
            }

            if !model.recentRepos.isEmpty {
                Text("切换最近仓库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                ForEach(model.recentRepos, id: \.self) { repo in
                    PopoverActionRow(
                        icon: repo == model.repoURLString && model.repoInfo != nil ? "checkmark.circle.fill" : "externaldrive",
                        iconColor: repo == model.repoURLString && model.repoInfo != nil ? .green : .secondary,
                        title: repo
                    ) {
                        model.showRepoPopover = false
                        model.repoURLString = repo
                        model.connect()
                    }
                }
                Divider()
            }

            PopoverActionRow(icon: "gearshape", title: "连接与证书设置…") {
                model.showRepoPopover = false
                model.showConnectSheet = true
            }

            if let host = URL(string: model.repoURLString).flatMap(SVNOrigin.init)?.endpoint,
               (!model.trustedHosts.contains(host) || model.certificateIssue != nil) {
                PopoverActionRow(icon: "checkmark.shield", iconColor: .orange, title: "信任 \(host) 证书并连接") {
                    model.showRepoPopover = false
                    model.trustServerCertificateAndConnect()
                }
            }

            if model.repoInfo != nil || !model.repoURLString.isEmpty {
                PopoverActionRow(icon: "arrow.clockwise", title: "重新连接仓库") {
                    model.showRepoPopover = false
                    model.connect()
                }
            }

            if let info = model.repoInfo {
                PopoverActionRow(icon: "doc.on.doc", title: "复制仓库 URL") {
                    model.showRepoPopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.url.absoluteString, forType: .string)
                    model.statusText = "已复制仓库 URL"
                }

                Divider()

                PopoverActionRow(icon: "xmark.circle", iconColor: .red, title: "断开连接", isDestructive: true) {
                    model.showRepoPopover = false
                    model.disconnect()
                }
            }
        }
        .padding(8)
        .frame(minWidth: 300, maxWidth: 420)
    }

    // MARK: - 工作副本 / 路径下拉弹窗

    private var workspaceMenuPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.workingCopyPath.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前本地工作副本")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(model.workingCopyPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                PopoverActionRow(icon: "arrow.up.forward.app", title: "在 Finder 中显示") {
                    model.showWorkspacePopover = false
                    model.revealWorkingCopyInFinder()
                }
                PopoverActionRow(icon: "arrow.down.circle", title: "执行 SVN Update 同步到最新") {
                    model.showWorkspacePopover = false
                    model.update()
                }
                PopoverActionRow(icon: "arrow.triangle.merge", title: "合并指定修订…") {
                    model.showWorkspacePopover = false
                    model.requestWorkspaceOperation(.merge)
                }
                .disabled(model.isBusy)
                .help("先预演，再应用到当前工作副本")
                PopoverActionRow(icon: "folder.badge.minus", iconColor: .red, title: "移除本地工作副本关联", isDestructive: true) {
                    model.showWorkspacePopover = false
                    model.clearWorkingCopy()
                }

                Divider()
            }

            PopoverActionRow(icon: "folder", title: "选择本地工作副本目录…") {
                model.showWorkspacePopover = false
                model.chooseWorkingCopyDirectory()
            }

            if model.repoInfo != nil {
                Divider()
                PopoverActionRow(icon: "square.and.arrow.down", title: "检出到指定位置…") {
                    model.showWorkspacePopover = false
                    model.checkoutWithPanel(entry: model.selectedEntry)
                }
                PopoverActionRow(icon: "bolt.horizontal", title: "快速检出到临时目录") {
                    model.showWorkspacePopover = false
                    model.checkout(entry: model.selectedEntry)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 280, maxWidth: 380)
    }
}

private struct PopoverActionRow: View {
    let icon: String
    var iconColor: Color = .primary
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isDestructive ? .red : iconColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isDestructive ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarSegmentCell: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    let showChevron: Bool
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
    }
}
