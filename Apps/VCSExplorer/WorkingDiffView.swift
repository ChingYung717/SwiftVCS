import CVCSKit
import SwiftUI

struct WorkingDiffView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let status = model.selectedStatus {
            DiffViewer(
                filePath: status.path,
                actionBadge: Theme.statusGlyph(status.kind),
                state: model.workingDiffState,
                onRetry: {
                    model.selectWorkingStatus(status)
                }
            ) {
                HStack(spacing: 6) {
                    if status.kind == .conflicted {
                        ConflictActions(status: status)
                    }

                    if status.kind == .unversioned {
                        Button {
                            model.add(status)
                        } label: {
                            Label("纳入版本控制", systemImage: "plus.circle")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if status.kind.isPendingChange {
                        Button(role: .destructive) {
                            model.pendingRevertStatus = status
                        } label: {
                            Label("放弃更改", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        model.revealStatusItemInFinder(status)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在 Finder 中显示")
                }
            }
        } else {
            EmptyStateView(
                imageName: "no-changes",
                fallbackSymbol: "checkmark.seal",
                title: model.workingCopyPath.isEmpty
                    ? "尚未打开本地工作副本"
                    : (model.displayedWorkingStatuses.isEmpty ? "没有本地未提交改动" : "选择左侧文件查看差异"),
                subtitle: model.workingCopyPath.isEmpty
                    ? "请先在顶部工具栏或左侧选择本地 .svn 工作副本目录。"
                    : (model.displayedWorkingStatuses.isEmpty
                       ? "当前工作副本与远端基线保持一致。"
                       : "在左侧「更改」列表中点击任意文件，即可在此处查看并排或统一视图差异比对。"),
                maxImageWidth: 210,
                maxImageHeight: 145
            )
        }
    }
}
