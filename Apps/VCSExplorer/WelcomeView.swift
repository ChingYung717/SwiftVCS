import CSVNKit
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                EmptyStateView(
                    imageName: "welcome",
                    fallbackSymbol: "externaldrive.connected.to.line.below.fill",
                    title: "欢迎使用 VCS Explorer",
                    subtitle: "参照 GitHub Desktop 体验打造的原生 macOS Subversion 客户端，支持提交文件级并排比对、远端仓库树浏览与工作副本管理。",
                    maxImageWidth: 280,
                    maxImageHeight: 190
                )

                // 三个主操作卡片
                HStack(spacing: 16) {
                    WelcomeActionCard(
                        icon: "server.rack",
                        title: "连接远端 SVN 仓库",
                        subtitle: "输入仓库 URL、凭据与自签名证书配置",
                        isPrimary: true
                    ) {
                        model.showConnectSheet = true
                    }

                    WelcomeActionCard(
                        icon: "folder.badge.gearshape",
                        title: "打开本地工作副本",
                        subtitle: "选择已有 .svn 目录查看变更、差异与提交",
                        isPrimary: false
                    ) {
                        model.chooseWorkingCopyDirectory()
                    }

                    if !model.repoURLString.isEmpty {
                        WelcomeActionCard(
                            icon: "bolt.horizontal.circle.fill",
                            title: "立即连接默认仓库",
                            subtitle: SVNURLSanitizer.redactForDisplay(model.repoURLString),
                            isPrimary: false
                        ) {
                            model.connect()
                        }
                    }
                }
                .frame(maxWidth: 760)

                // 最近仓库列表
                if !model.recentRepos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text("最近访问的仓库")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        VStack(spacing: 1) {
                            ForEach(model.recentRepos, id: \.self) { repo in
                                let displayRepo = SVNURLSanitizer.redactForDisplay(repo)
                                Button {
                                    model.repoURLString = SVNURLSanitizer.sanitizeForPersistence(repo) ?? displayRepo
                                    model.connect()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "externaldrive.fill")
                                            .foregroundStyle(Theme.brandBlue)
                                            .font(.system(size: 13))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(URL(string: displayRepo)?.lastPathComponent.isEmpty == false
                                                 ? (URL(string: displayRepo)?.lastPathComponent ?? displayRepo)
                                                 : displayRepo)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.primary)
                                            Text(displayRepo)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("点击连接")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Theme.brandBlue)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color(nsColor: .controlBackgroundColor))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .frame(maxWidth: 640)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WelcomeActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isPrimary ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.brandBlue.opacity(0.12)))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isPrimary ? .white : Theme.brandBlue)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isPrimary ? Theme.brandBlue.opacity(0.45) : Color.primary.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}
