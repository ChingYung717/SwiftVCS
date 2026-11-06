import CVCSKit
import SwiftUI

struct WorkspaceOperationSheet: View {
    @EnvironmentObject private var model: AppModel
    let operation: WorkspaceOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: operation.kind.title).font(.headline)
            Text(verbatim: operation.root)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if case .merge = operation.kind {
                mergeFields
            } else {
                if !operation.path.isEmpty { Text(verbatim: operation.path).textSelection(.enabled) }
                if operation.kind.needsDestination {
                    if case .rename = operation.kind {
                        TextField("新文件名", text: $model.operationDestination)
                    } else {
                        TextField("目标路径（相对工作副本）", text: $model.operationDestination)
                    }
                }
                if case .mkdir = operation.kind {
                    Toggle("同时新建缺失的父目录", isOn: $model.mkdirParents)
                    if let preview = model.matchingDirectoryPreview {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                resultPaths("将新建", paths: preview.newPaths)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                        .textSelection(.enabled)
                    }
                }
                if case .delete = operation.kind {
                    Text("文件会立即从本地移除，仓库在提交后变更。")
                } else if case .resolve = operation.kind {
                    Text("所选策略只处理此文件的文本冲突。覆盖型策略会替换当前内容。")
                } else {
                    Text("更改保留在本地工作副本，待检查后提交。")
                }
                if let error = model.errorText {
                    Text(verbatim: error).foregroundStyle(Theme.statusColor(.conflicted))
                }
                HStack {
                    Spacer()
                    closeButton("取消")
                    if case .mkdir = operation.kind {
                        Button("预览") { model.previewMkdir(operation) }
                            .disabled(model.isBusy || model.operationDestination.isEmpty)
                    }
                    Button("确认") { model.executeWorkspaceOperation(operation) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || (operation.kind.needsDestination && model.operationDestination.isEmpty) || requiresDirectoryPreview)
                        .help("应用到当前工作副本")
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isBusy)
    }

    private var requiresDirectoryPreview: Bool {
        if case .mkdir = operation.kind { return model.matchingDirectoryPreview == nil }
        return false
    }

    private var mergeFields: some View {
        let applied = model.mergeResult?.dryRun == false
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 8) {
                TextField("源分支 URL", text: $model.mergeSource)
                TextField("修订（N 或 A:B）", text: $model.mergeRange)
                TextField("Peg 修订（可选）", text: $model.mergePeg)
            }
            .disabled(model.isBusy || applied)

            Text("合并只写入工作副本。请在提交前审核文件与合并记录。")
                .foregroundStyle(.secondary)
            if let error = model.mergeError {
                Text(verbatim: error).foregroundStyle(Theme.statusColor(.conflicted))
            }
            if let result = model.mergeResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.dryRun ? "预演结果，工作副本未写入" : "应用结果，尚未提交")
                        .font(.subheadline.weight(.semibold))
                    if result.changedPaths.isEmpty && result.conflictedPaths.isEmpty &&
                        result.skippedPaths.isEmpty && !result.refreshRequired {
                        Text("没有可合并的变更")
                    }
                    if result.refreshRequired {
                        Text("合并已执行，实际状态需重新刷新。")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            resultPaths("变更", paths: result.changedPaths)
                            resultPaths("冲突", paths: result.conflictedPaths)
                            resultPaths("跳过", paths: result.skippedPaths)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack {
                Spacer()
                closeButton(applied ? "完成" : "关闭")
                if !applied {
                    Button("预演") { model.executeMerge(operation, dryRun: true) }
                        .disabled(model.isBusy || model.requestedMerge == nil)
                        .help("查看预计变更，不写入工作副本")
                    Button("应用合并") { model.executeMerge(operation, dryRun: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.mergeResult?.dryRun != true ||
                                  model.mergeResult?.request != model.requestedMerge)
                        .help("使用已预演的参数应用到工作副本")
                }
            }
        }
    }

    @ViewBuilder
    private func resultPaths(_ label: String, paths: [String]) -> some View {
        if !paths.isEmpty {
            Text(verbatim: "\(label)（\(paths.count)）")
                .font(.caption.weight(.semibold))
            ForEach(paths, id: \.self) { path in
                Text(verbatim: path).font(.caption.monospaced())
            }
        }
    }

    private func closeButton(_ label: String) -> some View {
        Button(label) { model.workspaceOperation = nil }
            .disabled(model.isBusy)
            .keyboardShortcut(.cancelAction)
            .help("关闭操作面板")
    }
}

struct ConflictActions: View {
    @EnvironmentObject private var model: AppModel
    let status: WorkingCopyStatus

    var body: some View {
        Menu("解决冲突") {
            if !status.resolutions.isEmpty {
                Button("打开工作文件…") { model.openConflictFile(status) }
                    .help("用默认编辑器打开工作文件")
                ForEach(ConflictResolution.allCases, id: \.self) { strategy in
                    Button(strategy.displayName) {
                        model.requestWorkspaceOperation(.resolve(strategy), path: status.path)
                    }
                    .disabled(!status.resolutions.contains(strategy))
                    .help(strategy.displayName)
                }
            } else {
                Text("该冲突类型需要单独处理")
            }
        }
        .disabled(model.isBusy)
        .help("查看当前文件支持的冲突处理策略")
    }
}
