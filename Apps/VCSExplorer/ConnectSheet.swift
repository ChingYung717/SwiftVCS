import CSVNKit
import SwiftUI

struct ConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var currentHost: String? {
        URL(string: model.repoURLString.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap(SVNOrigin.init).flatMap { $0.scheme == "https" ? $0.endpoint : nil }
    }

    private var isCurrentHostTrusted: Bool {
        guard let h = currentHost else { return false }
        return model.trustedHosts.contains(h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题栏
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.brandGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "server.rack")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接 SVN 仓库与证书设置")
                        .font(.system(size: 16, weight: .bold))
                    Text("配置 Subversion 远端地址、认证凭据及企业内部自签名 TLS 证书")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. 远端仓库地址
                    SheetSectionCard(title: "远端仓库地址") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text("仓库 URL")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)

                                TextField(
                                    "",
                                    text: $model.repoURLString,
                                    prompt: Text(verbatim: "https://svn.example.com/repo")
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .multilineTextAlignment(.leading)

                                if !model.recentRepos.isEmpty {
                                    Menu {
                                        ForEach(model.recentRepos, id: \.self) { r in
                                            let displayRepo = SVNURLSanitizer.redactForDisplay(r)
                                            Button(displayRepo) {
                                                model.repoURLString = SVNURLSanitizer.sanitizeForPersistence(r) ?? displayRepo
                                            }
                                        }
                                    } label: {
                                        Text("最近")
                                            .font(.system(size: 12))
                                    }
                                    .frame(width: 66)
                                }
                            }

                            if let info = model.repoInfo {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.system(size: 12.5))
                                    Text(verbatim: "当前已连接：\(SVNURLSanitizer.redactForDisplay(info.url.absoluteString))（最新 r\(info.youngestRevision)）")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.leading, 92)
                            }
                        }
                    }

                    // 2. 认证凭据
                    SheetSectionCard(title: "认证凭据") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Text("用户名")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)

                                TextField(
                                    "",
                                    text: $model.username,
                                    prompt: Text("输入 SVN 账号（可选）")
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.leading)
                            }

                            HStack(spacing: 10) {
                                Text("口令 / 密码")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)

                                SecureField(
                                    "",
                                    text: $model.password,
                                    prompt: Text("输入 SVN 密码（可选）")
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.leading)
                            }

                            Divider()

                            HStack {
                                Text("记住 HTTPS 凭据（macOS 钥匙串）")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Toggle("", isOn: $model.rememberPassword)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                        }
                    }

                    // 3. TLS / SSL 证书信任管理
                    SheetSectionCard(title: "TLS / SSL 证书信任例外管理") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let host = currentHost {
                                HStack(spacing: 10) {
                                    Image(systemName: isCurrentHostTrusted ? "checkmark.shield.fill" : "exclamationmark.shield")
                                        .foregroundStyle(isCurrentHostTrusted ? .green : .orange)
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: isCurrentHostTrusted
                                             ? "已配置服务器 \(host) 的自签名/未知 CA 证书信任例外"
                                             : "尚未导入 \(host) 的自签名/未知 CA 证书信任例外")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(isCurrentHostTrusted
                                             ? "仅对该 host:port 上指纹匹配的叶证书豁免未知 CA（非全局强固定）；主机名（SAN/CN）与有效期仍强制校验"
                                             : "若该仓库使用自签名证书，请先抓取并核对 SHA-256 指纹；证书 SAN/CN 必须与目标主机名一致")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        model.probeServerCertificate()
                                    } label: {
                                        Label(isCurrentHostTrusted ? "重新核验服务器证书" : "抓取并核验服务器证书", systemImage: "checkmark.shield")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isBusy)
                                }
                            }

                            if let probed = model.pendingProbedCertificate {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                            .foregroundStyle(.orange)
                                        Text(verbatim: "待确认服务器证书：\(probed.host):\(probed.port)（主体：\(probed.subjectSummary)）")
                                            .font(.system(size: 12.5, weight: .semibold))
                                    }
                                    Text(verbatim: "SHA-256 指纹：\(probed.sha256Fingerprint)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color.primary.opacity(0.05))
                                        )
                                    HStack(spacing: 8) {
                                        Text("请确认上述 SHA-256 指纹与服务器管理员提供的证书指纹一致（仅豁免未知 CA，主机名与有效期仍受检）。")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("取消") {
                                            model.cancelPendingCertificate()
                                        }
                                        .controlSize(.small)
                                        Button("确认指纹无误，信任并连接") {
                                            model.confirmPendingCertificateAndConnect(dismissOnSuccess: true)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(model.isBusy)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.orange.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                                )
                            }

                            if let certIssue = model.certificateIssue {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(verbatim: "证书提示：\(certIssue)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.orange)
                                }
                            }

                            if !model.trustedCertificates.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("已导入的服务器证书信任例外（仅豁免未知 CA，不绕过主机名或过期校验）：")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    ForEach(model.trustedCertificates, id: \.name) { cert in
                                        HStack(alignment: .center, spacing: 8) {
                                            Image(systemName: "lock.shield")
                                                .foregroundStyle(.green)
                                                .font(.system(size: 12.5))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(verbatim: cert.name)
                                                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                                if !cert.sha256Fingerprint.isEmpty {
                                                    Text(verbatim: "SHA-256: \(cert.sha256Fingerprint)")
                                                        .font(.system(size: 10.5, design: .monospaced))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                        .textSelection(.enabled)
                                                }
                                            }
                                            Spacer()
                                            Button(role: .destructive) {
                                                model.removeTrustedCertificate(cert.name)
                                            } label: {
                                                Label("移除", systemImage: "trash")
                                                    .font(.system(size: 11.5))
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                            }
                        }
                    }

                    // 4. 本地工作副本（可选）
                    SheetSectionCard(title: "本地工作副本（可选）") {
                        HStack(spacing: 10) {
                            Text("本地目录")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .leading)

                            TextField(
                                "",
                                text: $model.workingCopyPath,
                                prompt: Text("选择或输入本地 .svn 工作副本路径")
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .multilineTextAlignment(.leading)

                            Button("浏览…") {
                                model.chooseWorkingCopyDirectory()
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
                .padding(20)
            }

            if let err = model.errorText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }

            Divider()

            // 底部操作栏
            HStack(spacing: 12) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在连接仓库…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.repoInfo != nil {
                    Button("断开当前连接", role: .destructive) {
                        model.disconnect()
                        dismiss()
                    }
                }

                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(model.repoInfo == nil ? "连接仓库" : "重新连接") {
                    model.connect(dismissSheetOnSuccess: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.repoURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 580, height: 560)
    }
}

private struct SheetSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
        }
    }
}
