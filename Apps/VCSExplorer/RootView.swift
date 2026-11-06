import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("diffMode") private var diffModeRaw: String = DiffMode.split.rawValue

    private var shouldShowWelcome: Bool {
        model.repoInfo == nil &&
        model.workingCopyPath.isEmpty &&
        model.logs.isEmpty &&
        model.entries.isEmpty &&
        !model.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部三段式工具栏（仿 GitHub Desktop）
            RepoToolbar()

            // 全局可关闭错误横幅
            if let errorText = model.errorText, !errorText.isEmpty {
                ErrorBannerView(message: errorText) {
                    model.errorText = nil
                }
            }

            // 主工作区
            if shouldShowWelcome {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    SidebarView()
                        .frame(minWidth: 295, idealWidth: 325, maxWidth: 375)

                    detailWorkspace
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // 底部轻量状态栏
            bottomStatusBar
        }
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
                .environmentObject(model)
        }
        .background {
            // 全局快捷键绑定（仅保留带 ⌘ 修饰的标准快捷键，避免拦截输入框方向键或与系统冲突）
            Group {
                Button("") { model.selectSidebarTab(.history) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { model.selectSidebarTab(.changes) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { model.selectSidebarTab(.browse) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { model.chooseWorkingCopyDirectory() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("") { model.showConnectSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("") {
                    diffModeRaw = (diffModeRaw == DiffMode.split.rawValue)
                        ? DiffMode.unified.rawValue
                        : DiffMode.split.rawValue
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var detailWorkspace: some View {
        switch model.sidebarTab {
        case .history:
            CommitDetailView()
        case .changes:
            WorkingDiffView()
        case .browse:
            FilePreviewView()
        }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.repoInfo != nil ? Color.green : (model.workingCopyPath.isEmpty ? Color.secondary.opacity(0.4) : Color.orange))
                .frame(width: 7, height: 7)

            Text(model.statusText.isEmpty ? "就绪" : model.statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let info = model.repoInfo {
                Text(verbatim: "UUID: \(info.uuid?.prefix(8) ?? "—") · HEAD r\(info.youngestRevision)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text("⌘1 历史 · ⌘2 更改 · ⌘3 浏览 · ⌘⇧D 切换并排/统一")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ErrorBannerView: View {
    @EnvironmentObject private var model: AppModel
    let message: String
    let onClose: () -> Void

    private var looksLikeCertError: Bool {
        message.localizedCaseInsensitiveContains("certificate") ||
        message.localizedCaseInsensitiveContains("SSL") ||
        message.localizedCaseInsensitiveContains("TLS")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()

            if looksLikeCertError {
                Button("信任证书并重连") {
                    model.trustServerCertificateAndConnect()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }

            Button("连接设置…") {
                model.showConnectSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
