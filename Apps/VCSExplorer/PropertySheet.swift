import CVCSKit
import SwiftUI

struct PropertySheet: View {
    @EnvironmentObject private var model: AppModel
    let inspection: PropertyInspection

    private var editable: Bool {
        NodeProperty.allowsEditing(model.propertyName) && !model.nodeProperties.contains {
            $0.source == nil && $0.name == model.propertyName && $0.textValue == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(inspection.isWorkingCopy ? "工作副本节点属性" : "仓库节点属性（只读）").font(.headline)
            Text(verbatim: inspection.target.displayPath).textSelection(.enabled)
            if model.isBusy { ProgressView().controlSize(.small) }
            if model.nodeProperties.isEmpty && !model.isBusy && model.errorText == nil {
                Text("没有节点属性").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.nodeProperties) { property in
                        propertyRow(property)
                        Divider()
                    }
                    if let rules = model.nodeIgnoreRules {
                        ignoreSection(rules)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 205)
            if inspection.isWorkingCopy {
                TextField("属性名", text: $model.propertyName)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("node-property-name")
                Text("属性文本（留空会保存空值）").font(.caption)
                TextEditor(text: $model.propertyValue)
                    .font(.body.monospaced())
                    .frame(height: 70)
                    .border(.quaternary)
                    .disabled(model.isBusy || !editable)
                    .accessibilityLabel("属性文本")
                Text("保存后可在「更改」中查看，提交前只影响本地。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = model.propertyFeedback { Text(verbatim: feedback) }
            if let error = model.errorText { Text(verbatim: error).foregroundStyle(Theme.statusColor(.conflicted)) }
            HStack {
                Spacer()
                Button("关闭") { model.propertyInspection = nil }
                    .disabled(model.isBusy)
                    .keyboardShortcut(.cancelAction)
                if inspection.isWorkingCopy {
                    Button("保存属性") { model.changeProperty(inspection, name: model.propertyName, text: model.propertyValue) }
                        .disabled(model.isBusy || !editable)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .interactiveDismissDisabled(model.isBusy)
        .confirmationDialog("删除本地属性？", isPresented: Binding(
            get: { model.pendingPropertyDeletion != nil },
            set: { if !$0 { model.pendingPropertyDeletion = nil } }
        ), titleVisibility: .visible, presenting: model.pendingPropertyDeletion) { propertyName in
            Button("删除", role: .destructive) {
                model.changeProperty(inspection, name: propertyName, text: nil)
                if model.propertyName == propertyName {
                    model.propertyName = ""
                    model.propertyValue = ""
                }
                model.pendingPropertyDeletion = nil
            }
        } message: { propertyName in
            Text(verbatim: "「\(propertyName)」将从此工作副本节点移除，提交后才会影响仓库。")
        }
    }

    private func propertyRow(_ property: NodeProperty) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: property.name).font(.subheadline.weight(.semibold))
                Spacer()
                if property.isEditable {
                    if let text = property.textValue {
                        Button("编辑") { model.propertyName = property.name; model.propertyValue = text }
                            .disabled(model.isBusy)
                    }
                    Button("删除…") { model.pendingPropertyDeletion = property.name }
                        .disabled(model.isBusy)
                }
            }
            Text(verbatim: property.source.map { "继承自 \($0)" } ?? "直接设置")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            let preview = property.textValue.map { $0.isEmpty ? "（空值）" : $0 }
            Text(verbatim: preview ?? "二进制属性，\(property.value.count) 字节")
                .font(.caption.monospaced()).lineLimit(5).textSelection(.enabled)
        }
    }

    private func ignoreSection(_ rules: IgnoreRules) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("忽略规则").font(.subheadline.weight(.semibold))
            Text(verbatim: "配置默认：\(rules.defaults.joined(separator: "  "))")
            Text(verbatim: "本目录 svn:ignore：\(rules.directoryRules?.textValue ?? "未设置")")
            if rules.globalRules.isEmpty {
                Text("svn:global-ignores：未设置")
            }
            ForEach(rules.globalRules) { rule in
                Text(verbatim: "svn:global-ignores · \(rule.source ?? "本目录")：\(rule.textValue ?? "二进制属性")")
            }
            Button("编辑本目录忽略规则") {
                model.propertyName = "svn:ignore"
                model.propertyValue = rules.directoryRules?.textValue ?? ""
            }
            .disabled(model.isBusy || (rules.directoryRules != nil && rules.directoryRules?.textValue == nil))
        }
        .font(.caption)
        .textSelection(.enabled)
    }
}
