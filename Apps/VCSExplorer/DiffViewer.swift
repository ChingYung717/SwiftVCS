import AppKit
import CVCSKit
import SwiftUI

struct DiffViewer<TrailingActions: View>: View {
    @EnvironmentObject private var model: AppModel
    let filePath: String
    let actionBadge: String?
    let state: FileDiffLoadState
    let onRetry: (() -> Void)?
    @ViewBuilder let trailingActions: () -> TrailingActions

    @AppStorage("diffMode") private var diffModeRaw: String = DiffMode.split.rawValue
    @AppStorage("diffWrapLines") private var wrapLines: Bool = false

    init(
        filePath: String,
        actionBadge: String? = nil,
        state: FileDiffLoadState,
        onRetry: (() -> Void)? = nil,
        @ViewBuilder trailingActions: @escaping () -> TrailingActions = { EmptyView() }
    ) {
        self.filePath = filePath
        self.actionBadge = actionBadge
        self.state = state
        self.onRetry = onRetry
        self.trailingActions = trailingActions
    }

    private var currentMode: DiffMode {
        DiffMode(rawValue: diffModeRaw) ?? .split
    }

    private var loadedDiff: FileDiff? {
        if case .loaded(let d, _) = state { return d }
        return nil
    }

    private var hasTextDiff: Bool {
        guard let d = loadedDiff, !d.isBinary, !d.hunks.isEmpty else { return false }
        return true
    }

    private var fileNamePart: String {
        let trimmed = filePath.hasSuffix("/") && filePath.count > 1 ? String(filePath.dropLast()) : filePath
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private var directoryPart: String {
        let trimmed = filePath.hasSuffix("/") && filePath.count > 1 ? String(filePath.dropLast()) : filePath
        guard let idx = trimmed.lastIndex(of: "/"), idx > trimmed.startIndex else {
            return ""
        }
        return String(trimmed[trimmed.startIndex..<idx])
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部文件信息与模式切换栏
            diffToolbar

            Divider()

            // 主体区域
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 顶部工具条

    private var diffToolbar: some View {
        HStack(spacing: 8) {
            if let badge = actionBadge, !badge.isEmpty {
                ActionBadgeView(action: badge)
            }

            let iconInfo = FileIcon.symbol(
                for: filePath,
                isDirectory: {
                    if case .directory = state { return true }
                    return false
                }()
            )
            Image(systemName: iconInfo.symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(iconInfo.color)

            if filePath.isEmpty {
                Text("未选择文件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fileNamePart)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if !directoryPart.isEmpty {
                        Text(directoryPart)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }

            if !filePath.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filePath, forType: .string)
                    model.statusText = "已复制路径 \(filePath)"
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String("复制完整文件路径 \(filePath)"))
            }

            if let diff = loadedDiff, !diff.isBinary {
                HStack(spacing: 6) {
                    Text(verbatim: "+\(diff.addedCount)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.addFG)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.addBG))

                    Text(verbatim: "−\(diff.removedCount)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.delFG)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.delBG))
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 8)

            trailingActions()
                .fixedSize(horizontal: true, vertical: false)

            if hasTextDiff {
                // 自动换行开关
                Button {
                    wrapLines.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: wrapLines ? "text.word.spacing" : "arrow.left.and.right.text.vertical")
                            .font(.system(size: 11.5))
                        Text(wrapLines ? "自动换行" : "横向滚动")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(wrapLines ? Theme.brandBlue.opacity(0.14) : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(wrapLines ? Theme.brandBlue : .secondary)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("切换长代码行自动换行或横向滚动")

                // 并排对比 / 统一视图 切换器
                HStack(spacing: 2) {
                    ForEach(DiffMode.allCases) { mode in
                        let active = currentMode == mode
                        Button {
                            diffModeRaw = mode.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 11))
                                Text(mode.label)
                                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(active ? Theme.brandBlue : Color.clear)
                            )
                            .foregroundStyle(active ? .white : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .fixedSize(horizontal: true, vertical: false)
                .help("切换并排对比与统一视图 (⌘⇧D)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 主体状态分发

    @ViewBuilder
    private var contentArea: some View {
        switch state {
        case .idle:
            EmptyStateView(
                imageName: "select-commit",
                fallbackSymbol: "doc.text.magnifyingglass",
                title: "选择文件查看代码差异",
                subtitle: "在左侧文件列表中点击任意改动文件，即可在此处查看并排或统一视图比对。",
                maxImageWidth: 160,
                maxImageHeight: 115
            )

        case .loading:
            loadingSkeletonView

        case .directory(let path):
            directoryChangePlaceholder(path: path)

        case .binary(let path, let size):
            binaryPlaceholderCard(path: path, size: size)

        case .failed(let message):
            EmptyStateView(
                fallbackSymbol: "exclamationmark.triangle.fill",
                title: "无法加载文件差异",
                subtitle: message,
                maxImageWidth: 120,
                maxImageHeight: 90
            ) {
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("重试加载", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

        case .loaded(let diff, let isTruncated):
            if diff.isBinary || (diff.hunks.isEmpty && FileIcon.isKnownBinaryExtension(filePath)) {
                binaryPlaceholderCard(path: filePath, size: nil)
            } else if diff.hunks.isEmpty {
                EmptyStateView(
                    fallbackSymbol: "checkmark.seal",
                    title: "无文本行差异",
                    subtitle: diff.statusNotice ?? "该文件在此次变更中无可见正文差异（可能仅包含 SVN 属性或空白变更）。",
                    maxImageWidth: 120,
                    maxImageHeight: 90
                )
            } else {
                diffCodeScrollArea(diff: diff, isTruncated: isTruncated)
            }
        }
    }

    // MARK: - 加载骨架态

    private var loadingSkeletonView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: "正在从仓库加载 \(filePath.split(separator: "/").last.map(String.init) ?? "文件") 的差异比对…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 6)

            ForEach(0..<8, id: \.self) { idx in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 40, height: 14)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            idx % 3 == 1
                                ? Theme.addBG
                                : (idx % 4 == 2 ? Theme.delBG : Color.secondary.opacity(0.10))
                        )
                        .frame(width: CGFloat(180 + (idx * 73) % 280), height: 14)
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 目录节点变更说明卡片

    private func directoryChangePlaceholder(path: String) -> some View {
        let actionTitle: String = {
            switch actionBadge?.uppercased() {
            case "A": return "新增目录节点"
            case "D": return "删除目录节点"
            case "M": return "修改目录属性"
            case "R": return "替换目录节点"
            default:  return "目录节点变更"
            }
        }()
        let actionSubtitle: String = {
            switch actionBadge?.uppercased() {
            case "A": return "该目录在此次提交中被创建（或从分支复制新增），目录本身不包含文本行差异，请点击左侧该目录下的具体文件查看代码比对。"
            case "D": return "该目录在此次提交中被删除，目录本身不包含文本行差异。"
            case "M": return "该目录在此次提交中修改了 SVN 目录属性（如 svn:ignore / svn:mergeinfo），不包含正文代码行差异。"
            default:  return "路径 \(path) 是目录节点（新增/删除目录或目录属性变更），不包含文本行差异。"
            }
        }()

        return EmptyStateView(
            fallbackSymbol: "folder.fill.badge.gearshape",
            title: actionTitle,
            subtitle: actionSubtitle,
            maxImageWidth: 120,
            maxImageHeight: 90
        ) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    if let badge = actionBadge, !badge.isEmpty {
                        ActionBadgeView(action: badge)
                    }
                    Text(verbatim: path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !path.isEmpty {
                    Button {
                        model.showLogForPath(path)
                    } label: {
                        Label("查看此目录的提交历史", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 二进制文件占位卡片

    private func binaryPlaceholderCard(path: String, size: Int64?) -> some View {
        let ext = (path as NSString).pathExtension.uppercased()
        let icon = FileIcon.symbol(for: path)
        let actionDesc: String = {
            switch actionBadge?.uppercased() {
            case "A": return "在此变更中新增的二进制文件，无法按文本行展示差异"
            case "D": return "已在此变更中删除的二进制文件，无法按文本行展示差异"
            case "M": return "已修改的二进制文件，无法按文本行展示差异"
            case "R": return "已替换的二进制文件，无法按文本行展示差异"
            default:  return "二进制文件，无法按文本行展示差异"
            }
        }()

        return VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(icon.color.opacity(0.12))
                    .frame(width: 80, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(icon.color.opacity(0.3), lineWidth: 1)
                    )
                VStack(spacing: 4) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(icon.color)
                    if !ext.isEmpty {
                        Text(verbatim: ext)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(icon.color)
                    }
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    if let badge = actionBadge, !badge.isEmpty {
                        ActionBadgeView(action: badge)
                    }
                    Text(actionDesc)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(verbatim: path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let size, size > 0 {
                    Text(verbatim: "文件大小：\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 代码比对主滚动区

    @ViewBuilder
    private func diffCodeScrollArea(diff: FileDiff, isTruncated: Bool) -> some View {
        let totalLineCount = diff.hunks.reduce(0) { $0 + $1.lines.count }
        let lineLimit = model.showAllDiffLines ? Int.max : 5000
        let maxColumns: Int = {
            var m = 0
            var seen = 0
            for hunk in diff.hunks {
                for line in hunk.lines {
                    let c = DiffLineTextHelper.displayColumnCount(line.text)
                    if c > m { m = c }
                    seen += 1
                    if seen >= lineLimit { return m }
                }
            }
            return m
        }()

        GeometryReader { geo in
            let viewportWidth = max(480, geo.size.width)
            let viewportHalf = max(240, floor((viewportWidth - 1) / 2))
            let splitSideWidth: CGFloat? = wrapLines
                ? nil
                : max(viewportHalf, CGFloat(maxColumns) * 7.4 + 80)
            let totalContentWidth: CGFloat? = {
                if wrapLines { return viewportWidth }
                if currentMode == .split, let sw = splitSideWidth {
                    return sw * 2 + 1
                }
                return max(viewportWidth, CGFloat(maxColumns) * 7.4 + 130)
            }()

            ScrollView(wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isTruncated {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text("此文件差异较大，已按安全上限（2 MB）截断展示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.10))
                    }

                    if currentMode == .split {
                        splitDiffContent(diff: diff, maxLines: lineLimit, sideWidth: splitSideWidth)
                    } else {
                        unifiedDiffContent(diff: diff, maxLines: lineLimit)
                    }

                    if totalLineCount > 5000 && !model.showAllDiffLines {
                        HStack(spacing: 10) {
                            Image(systemName: "ellipsis.rectangle")
                                .foregroundStyle(Theme.brandBlue)
                            Text(verbatim: "为保证界面流畅，已展示前 5000 行（共 \(totalLineCount) 行）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(String("显示全部 \(totalLineCount) 行")) {
                                model.showAllDiffLines = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .frame(width: totalContentWidth, alignment: .leading)
            }
        }
    }

    // MARK: - 并排对比（Split）渲染

    @ViewBuilder
    private func splitDiffContent(diff: FileDiff, maxLines: Int, sideWidth: CGFloat?) -> some View {
        let budget = buildSplitHunkSlices(hunks: diff.hunks, maxRows: maxLines)
        ForEach(budget, id: \.hunk.id) { item in
            HunkHeaderBar(header: item.hunk.header)

            ForEach(item.rows) { row in
                SplitDiffRowView(row: row, wrapLines: wrapLines, sideWidth: sideWidth)
            }
        }
    }

    private func buildSplitHunkSlices(hunks: [FileDiff.Hunk], maxRows: Int) -> [(hunk: FileDiff.Hunk, rows: [UISplitDiffRow])] {
        var result: [(hunk: FileDiff.Hunk, rows: [UISplitDiffRow])] = []
        var remaining = maxRows
        for hunk in hunks {
            guard remaining > 0 else { break }
            let allRows = UISideBySideBuilder.rows(for: hunk)
            if allRows.count <= remaining {
                result.append((hunk, allRows))
                remaining -= allRows.count
            } else {
                result.append((hunk, Array(allRows.prefix(remaining))))
                remaining = 0
            }
        }
        return result
    }

    // MARK: - 统一视图（Unified）渲染

    @ViewBuilder
    private func unifiedDiffContent(diff: FileDiff, maxLines: Int) -> some View {
        let budget = buildUnifiedHunkSlices(hunks: diff.hunks, maxLines: maxLines)
        ForEach(budget, id: \.hunk.id) { item in
            HunkHeaderBar(header: item.hunk.header)

            ForEach(item.lines) { line in
                UnifiedDiffLineView(line: line, wrapLines: wrapLines)
            }
        }
    }

    private func buildUnifiedHunkSlices(hunks: [FileDiff.Hunk], maxLines: Int) -> [(hunk: FileDiff.Hunk, lines: [FileDiff.Hunk.Line])] {
        var result: [(hunk: FileDiff.Hunk, lines: [FileDiff.Hunk.Line])] = []
        var remaining = maxLines
        for hunk in hunks {
            guard remaining > 0 else { break }
            if hunk.lines.count <= remaining {
                result.append((hunk, hunk.lines))
                remaining -= hunk.lines.count
            } else {
                result.append((hunk, Array(hunk.lines.prefix(remaining))))
                remaining = 0
            }
        }
        return result
    }
}

// MARK: - 文本列宽估算与安全格式化辅助

private enum DiffLineTextHelper {
    /// 估算单行等宽显示列数：Tab 按 4 列、CJK 等双宽字符（scalar.value > 0x2E80）按 2 列计算
    static func displayColumnCount(_ text: String, maxChars: Int = 1200) -> Int {
        var cols = 0
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= maxChars { break }
            count += 1
            if scalar == "\t" {
                cols += 4
            } else if scalar.value > 0x2E80 {
                cols += 2
            } else {
                cols += 1
            }
        }
        return cols
    }

    /// 展开制表符为 4 个空格并限制单行最大字符长度
    static func safeCodeText(_ raw: String, maxChars: Int = 1200) -> String {
        if raw.isEmpty { return " " }
        let expanded = raw.contains("\t") ? raw.replacingOccurrences(of: "\t", with: "    ") : raw
        if expanded.count > maxChars {
            return String(expanded.prefix(maxChars)) + " …"
        }
        return expanded
    }
}

// MARK: - Hunk 头部条

private struct HunkHeaderBar: View {
    let header: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.horizontal.3.decrease")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.hunkFG)
            Text(verbatim: header)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.hunkFG)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.hunkBG)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

// MARK: - 并排模式单行组件

private struct SplitDiffRowView: View {
    let row: UISplitDiffRow
    let wrapLines: Bool
    let sideWidth: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SplitDiffHalfCell(
                line: row.left,
                isLeft: true,
                wrapLines: wrapLines
            )
            .frame(width: sideWidth)
            .frame(maxWidth: sideWidth == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            SplitDiffHalfCell(
                line: row.right,
                isLeft: false,
                wrapLines: wrapLines
            )
            .frame(width: sideWidth)
            .frame(maxWidth: sideWidth == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SplitDiffHalfCell: View {
    let line: FileDiff.Hunk.Line?
    let isLeft: Bool
    let wrapLines: Bool

    private var lineNumberText: String {
        guard let line else { return "" }
        if isLeft {
            return line.oldLine.map(String.init) ?? ""
        } else {
            return line.newLine.map(String.init) ?? ""
        }
    }

    private var prefixMarker: String {
        guard let line else { return " " }
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    private var safeCodeText: String {
        guard let raw = line?.text else { return "" }
        return DiffLineTextHelper.safeCodeText(raw)
    }

    private var gutterBackground: Color {
        guard let line else { return Theme.emptySplitBG }
        switch line.kind {
        case .addition: return Theme.addGutterBG
        case .deletion: return Theme.delGutterBG
        case .context: return Color.primary.opacity(0.02)
        }
    }

    private var codeBackground: Color {
        guard let line else { return Theme.emptySplitBG }
        switch line.kind {
        case .addition: return Theme.addBG
        case .deletion: return Theme.delBG
        case .context: return Color.clear
        }
    }

    private var markerForeground: Color {
        guard let line else { return .secondary }
        switch line.kind {
        case .addition: return Theme.addFG
        case .deletion: return Theme.delFG
        case .context: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: lineNumberText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.vertical, 1.5)

            Color.clear
                .frame(width: 1, height: 1)

            if line != nil {
                Text(verbatim: prefixMarker)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(markerForeground)
                    .frame(width: 16, alignment: .center)
                    .padding(.vertical, 1.5)

                Text(verbatim: safeCodeText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(wrapLines ? nil : 1)
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
                    .padding(.vertical, 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
                    .frame(maxWidth: .infinity, minHeight: 19)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            HStack(spacing: 0) {
                gutterBackground
                    .frame(width: 50)
                Color.primary.opacity(0.05)
                    .frame(width: 1)
                codeBackground
            }
        }
    }
}

// MARK: - 统一视图单行组件

private struct UnifiedDiffLineView: View {
    let line: FileDiff.Hunk.Line
    let wrapLines: Bool

    private var oldNum: String {
        line.oldLine.map(String.init) ?? ""
    }

    private var newNum: String {
        line.newLine.map(String.init) ?? ""
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    private var safeCodeText: String {
        DiffLineTextHelper.safeCodeText(line.text)
    }

    private var gutterBackground: Color {
        switch line.kind {
        case .addition: return Theme.addGutterBG
        case .deletion: return Theme.delGutterBG
        case .context: return Color.primary.opacity(0.02)
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: return Theme.addBG
        case .deletion: return Theme.delBG
        case .context: return Color.clear
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: return Theme.addFG
        case .deletion: return Theme.delFG
        case .context: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: oldNum)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 5)
                .padding(.vertical, 1.5)

            Color.clear
                .frame(width: 1, height: 1)

            Text(verbatim: newNum)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 5)
                .padding(.vertical, 1.5)

            Color.clear
                .frame(width: 1, height: 1)

            Text(verbatim: marker)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 18, alignment: .center)
                .padding(.vertical, 1.5)

            Text(verbatim: safeCodeText)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(wrapLines ? nil : 1)
                .textSelection(.enabled)
                .padding(.trailing, 10)
                .padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            HStack(spacing: 0) {
                gutterBackground
                    .frame(width: 47)
                Color.primary.opacity(0.05)
                    .frame(width: 1)
                gutterBackground
                    .frame(width: 47)
                Color.primary.opacity(0.05)
                    .frame(width: 1)
                rowBackground
            }
        }
    }
}
