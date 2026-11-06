import AppKit
import CVCSKit
import Foundation
import SwiftUI

// MARK: - 全局枚举与状态类型

enum SidebarTab: String, CaseIterable, Identifiable {
    case history = "历史"
    case changes = "更改"
    case browse = "浏览"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .changes: return "plus.forwardslash.minus"
        case .browse: return "folder"
        }
    }
}

enum DiffMode: String, CaseIterable, Identifiable {
    case split = "split"
    case unified = "unified"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .split: return "并排对比"
        case .unified: return "统一视图"
        }
    }

    var icon: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .unified: return "rectangle.grid.1x2"
        }
    }
}

enum FileDiffLoadState: Equatable {
    case idle
    case loading
    case loaded(FileDiff, isTruncated: Bool)
    case directory(String)
    case binary(path: String, size: Int64?)
    case failed(String)
}

// MARK: - 提交内单个变更项（兼容结构化 ChangedPath 与字符串 changedPaths）

struct UIChangedItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let action: String          // "A", "M", "D", "R"
    let path: String            // 如 "/Develop/module1/Foo.java"
    let isDirectory: Bool
    let nodeKind: ChangedPath.NodeKind
    let copyFromPath: String?
    let copyFromRevision: Int?

    var fileName: String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    var directoryPath: String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let idx = trimmed.lastIndex(of: "/"), idx > trimmed.startIndex else {
            return "/"
        }
        return String(trimmed[trimmed.startIndex..<idx])
    }

    var actionLabel: String {
        switch action {
        case "A": return "新增"
        case "M": return "修改"
        case "D": return "删除"
        case "R": return "替换"
        default: return action
        }
    }

    func toChangedPath() -> ChangedPath {
        ChangedPath(
            action: ChangedPath.Action(svnChar: action.first ?? "M"),
            path: path,
            kind: isDirectory ? .directory : nodeKind,
            copyFromPath: copyFromPath,
            copyFromRevision: copyFromRevision
        )
    }

    /// 从 `LogEntry` 提取变更列表（直接读取 `log.changes` 并推断未知目录项）
    static func extract(from log: LogEntry) -> [UIChangedItem] {
        let sourceChanges: [ChangedPath] = !log.changes.isEmpty
            ? log.changes
            : log.changedPaths.map { ChangedPath.parse($0) }

        let allPaths = sourceChanges.map(\.path)
        var seen = Set<String>()
        var items: [UIChangedItem] = []
        items.reserveCapacity(sourceChanges.count)

        for ch in sourceChanges {
            guard !ch.path.isEmpty, !seen.contains(ch.path) else { continue }
            seen.insert(ch.path)

            let isDir: Bool
            switch ch.kind {
            case .directory:
                isDir = true
            case .file:
                isDir = false
            case .unknown:
                let prefixWithSlash = ch.path.hasSuffix("/") ? ch.path : (ch.path + "/")
                let hasChildInCommit = allPaths.contains { other in
                    other != ch.path && other.hasPrefix(prefixWithSlash)
                }
                let ext = (ch.path as NSString).pathExtension
                isDir = ch.path.hasSuffix("/") || (hasChildInCommit && ext.isEmpty)
            }

            items.append(
                UIChangedItem(
                    action: ch.action.rawValue,
                    path: ch.path,
                    isDirectory: isDir,
                    nodeKind: isDir ? .directory : ch.kind,
                    copyFromPath: ch.copyFromPath,
                    copyFromRevision: ch.copyFromRevision
                )
            )
        }

        return items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

// MARK: - 并排对比（Split Diff）行构建器

typealias UISplitDiffRow = SplitDiffRow

enum UISideBySideBuilder {
    /// 直接复用 CVCSKit 中 FileDiff.Hunk.splitRows 的并排配对实现
    static func rows(for hunk: FileDiff.Hunk) -> [UISplitDiffRow] {
        hunk.splitRows
    }
}

// MARK: - 颜色与视觉令牌

enum Theme {
    /// 品牌渐变（#4F7DF3 → #8B5CF6）
    static let brandBlue = Color(red: 0x4F / 255.0, green: 0x7D / 255.0, blue: 0xF3 / 255.0)
    static let brandPurple = Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandBlue, brandPurple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 新增行背景（GitHub 风格绿）
    static let addBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.18, green: 0.64, blue: 0.31, alpha: 0.22)
            : NSColor(srgbRed: 0.18, green: 0.64, blue: 0.31, alpha: 0.14)
    })

    /// 新增行号槽背景
    static let addGutterBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.18, green: 0.64, blue: 0.31, alpha: 0.34)
            : NSColor(srgbRed: 0.18, green: 0.64, blue: 0.31, alpha: 0.25)
    })

    /// 删除行背景（GitHub 风格红）
    static let delBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 0.22)
            : NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 0.13)
    })

    /// 删除行号槽背景
    static let delGutterBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 0.34)
            : NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 0.24)
    })

    /// 新增前景文字色
    static let addFG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1.0)
            : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1.0)
    })

    /// 删除前景文字色
    static let delFG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.97, green: 0.32, blue: 0.29, alpha: 1.0)
            : NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 1.0)
    })

    /// Hunk 头部浅蓝背景
    static let hunkBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.22, green: 0.55, blue: 0.99, alpha: 0.16)
            : NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 0.09)
    })

    /// Hunk 头部文字色
    static let hunkFG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 1.0)
    })

    /// 并排模式空白侧背景
    static let emptySplitBG = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1.0, alpha: 0.03)
            : NSColor(white: 0.0, alpha: 0.035)
    })

    /// 顶栏背景
    static let toolbarBG = Color(nsColor: .windowBackgroundColor)

    /// 动作徽章颜色
    static func actionColor(_ action: String) -> Color {
        switch action.uppercased() {
        case "A": return Color(red: 0.18, green: 0.64, blue: 0.31)
        case "M": return Color(red: 0.82, green: 0.53, blue: 0.10)
        case "D": return Color(red: 0.81, green: 0.13, blue: 0.18)
        case "R": return Color(red: 0.04, green: 0.41, blue: 0.85)
        case "C": return Color(red: 0.51, green: 0.31, blue: 0.87)
        default: return .secondary
        }
    }

    static func statusGlyph(_ kind: WorkingCopyStatus.Kind) -> String {
        switch kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .replaced: return "R"
        case .conflicted: return "C"
        case .missing: return "!"
        case .unversioned: return "?"
        case .ignored: return "I"
        case .obstructed: return "~"
        case .normal: return "·"
        case .unknown: return "?"
        }
    }

    static func statusColor(_ kind: WorkingCopyStatus.Kind) -> Color {
        switch kind {
        case .added: return actionColor("A")
        case .modified: return actionColor("M")
        case .deleted, .missing: return actionColor("D")
        case .replaced: return actionColor("R")
        case .conflicted, .obstructed: return actionColor("C")
        case .unversioned, .ignored, .normal, .unknown: return .secondary
        }
    }
}

// MARK: - 作者圆形头像组件

struct AvatarView: View {
    let name: String
    var size: CGFloat = 28

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.31, green: 0.49, blue: 0.95), Color(red: 0.48, green: 0.35, blue: 0.94)),
        (Color(red: 0.16, green: 0.65, blue: 0.56), Color(red: 0.12, green: 0.52, blue: 0.72)),
        (Color(red: 0.88, green: 0.42, blue: 0.24), Color(red: 0.85, green: 0.25, blue: 0.42)),
        (Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.78, green: 0.31, blue: 0.75)),
        (Color(red: 0.15, green: 0.58, blue: 0.88), Color(red: 0.25, green: 0.40, blue: 0.88)),
        (Color(red: 0.20, green: 0.68, blue: 0.38), Color(red: 0.14, green: 0.55, blue: 0.46)),
        (Color(red: 0.85, green: 0.55, blue: 0.15), Color(red: 0.88, green: 0.36, blue: 0.18)),
        (Color(red: 0.42, green: 0.47, blue: 0.58), Color(red: 0.28, green: 0.33, blue: 0.44)),
    ]

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        // 若包含中文字符，取最后一个汉字；否则取前 1~2 个英文字母大写
        let scalars = Array(trimmed.unicodeScalars)
        if scalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return String(trimmed.suffix(1))
        }
        let parts = trimmed.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == " " })
        if parts.count >= 2, let f = parts.first?.first, let l = parts.last?.first {
            return "\(f)\(l)".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    private var gradientColors: (Color, Color) {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    var body: some View {
        let pair = gradientColors
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [pair.0, pair.1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: max(10, size * 0.40), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .help(name.isEmpty ? "未知作者" : name)
    }
}

// MARK: - 动作与状态徽章组件

struct ActionBadgeView: View {
    let action: String
    var isSelected: Bool = false

    var body: some View {
        let color = Theme.actionColor(action)
        Text(verbatim: action.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(isSelected ? .white : color)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : color.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.45) : color.opacity(0.35), lineWidth: 0.5)
            )
    }
}

struct WCStatusBadgeView: View {
    let kind: WorkingCopyStatus.Kind
    var isSelected: Bool = false

    var body: some View {
        let glyph = Theme.statusGlyph(kind)
        let color = Theme.statusColor(kind)
        Text(verbatim: glyph)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(isSelected ? .white : color)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : color.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.45) : color.opacity(0.35), lineWidth: 0.5)
            )
            .help(kind.displayName)
    }
}

// MARK: - 相对时间格式化

enum RelativeTime {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func format(_ date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 {
            return "刚刚"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) 小时前"
        }
        let days = hours / 24
        if days == 1 {
            return "昨天"
        }
        if days < 30 {
            return "\(days) 天前"
        }
        let months = days / 30
        if months < 12 {
            return "\(months) 个月前"
        }
        return shortDateFormatter.string(from: date)
    }

    static func fullFormat(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }
}

// MARK: - 文件图标与二进制识别

enum FileIcon {
    private static let binaryExtensions: Set<String> = [
        "jar", "war", "ear", "class", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "icns", "tiff", "psd",
        "pdf", "xls", "xlsx", "doc", "docx", "ppt", "pptx",
        "so", "dylib", "dll", "exe", "bin", "dat", "o", "a", "pyc", "wasm",
        "mp3", "mp4", "mov", "avi", "wav", "ttf", "otf", "woff", "woff2", "sqlite", "db"
    ]

    static func isKnownBinaryExtension(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return binaryExtensions.contains(ext)
    }

    static func symbol(for path: String, isDirectory: Bool = false) -> (symbol: String, color: Color) {
        if isDirectory || path.hasSuffix("/") {
            return ("folder.fill", .blue)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "java", "kt", "kts", "scala", "groovy":
            return ("chevron.left.forwardslash.chevron.right", .orange)
        case "swift", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go":
            return ("chevron.left.forwardslash.chevron.right", .blue)
        case "js", "jsx", "ts", "tsx", "vue", "py", "rb", "php", "sh", "zsh", "bash":
            return ("chevron.left.forwardslash.chevron.right", .teal)
        case "xml", "json", "yml", "yaml", "plist", "properties", "toml", "ini", "conf", "gradle":
            return ("curlybraces", .purple)
        case "html", "htm", "css", "scss", "less", "jsp", "ftl":
            return ("globe", .cyan)
        case "sql":
            return ("cylinder.split.1x2", .indigo)
        case "jar", "war", "ear", "zip", "tar", "gz", "7z", "rar":
            return ("archivebox.fill", .brown)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns":
            return ("photo", .pink)
        case "xls", "xlsx", "csv":
            return ("tablecells", .green)
        case "doc", "docx", "pdf", "rtf":
            return ("doc.richtext", .red)
        case "md", "markdown", "txt", "log":
            return ("doc.text", .secondary)
        case "class", "o", "so", "dylib", "dll", "exe":
            return ("cpu", .secondary)
        default:
            return ("doc.text", .secondary)
        }
    }
}
