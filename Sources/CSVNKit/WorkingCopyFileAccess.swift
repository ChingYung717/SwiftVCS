import Darwin
import Foundation

public enum WorkingCopyFileError: Error, Equatable, Sendable {
    case invalidPath
    case openFailed(Int32)
    case notRegularFile
    case hardLinked
    case outsideRoot
}

public struct ConfinedOpenResult: Sendable {
    public let fileDescriptor: Int32
    public let canonicalPath: String
    public let fileSize: Int64
}

/// 工作副本内的受限本地文件访问工具：逐段 `openat(..., O_NOFOLLOW | O_CLOEXEC)` 遍历父目录与目标，
/// 并通过 `fstat` (`S_IFREG`、`st_nlink == 1`) 与 `F_GETPATH` 强制约束目标位于已解析的工作副本根目录内。
public enum WorkingCopyFileAccess {
    /// 富文本/HTML/SVG/XML/OpenDocument/WordML 等会被 TextEdit.app 按富文本或 WebKit 渲染的扩展名。
    public static let unsafeTextEditExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "shtm", "mht", "mhtml",
        "svg", "rtf", "rtfd", "webarchive",
        "doc", "docx", "docm", "dot", "dotx", "wordml", "xml",
        "odt", "ott", "sxw", "stw"
    ]

    public static func isUnsafeForTextEdit(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && unsafeTextEditExtensions.contains(ext)
    }

    /// 嗅探已打开文件头部字节，拦截无扩展名或伪装为纯文本的 RTF/HTML/XML/WordML/WebArchive 富文本内容。
    public static func isUnsafeTextEditData(_ prefixData: Data) -> Bool {
        guard !prefixData.isEmpty else { return false }
        var bytes = Array(prefixData.prefix(512))
        // Strip optional UTF-8 BOM
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        // Check binary plist (webarchive) or ZIP archive (docx/odt) headers before trimming ASCII whitespace
        if bytes.starts(with: "bplist00".utf8) {
            return true
        }
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04 {
            return true
        }
        var start = 0
        while start < bytes.count {
            let b = bytes[start]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C {
                start += 1
            } else {
                break
            }
        }
        guard start < bytes.count else { return false }
        let slice = bytes[start...]
        let lowered = String(decoding: slice.prefix(64), as: UTF8.self).lowercased()
        let unsafePrefixes = [
            "{\\rtf",
            "<!doctype html",
            "<html",
            "<?xml",
            "<?mso-application",
            "<svg",
            "<!doctype svg"
        ]
        return unsafePrefixes.contains { lowered.hasPrefix($0) }
    }

    /// 通过 `pread` 从已打开的受限 FD 嗅探文件头部（不改变文件偏移量）。
    public static func isUnsafeTextEditContent(fileDescriptor fd: Int32) -> Bool {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.pread(fd, &buf, buf.count, 0)
            if n > 0 {
                return isUnsafeTextEditData(Data(buf[..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
    }

    private static func getFDPath(_ fd: Int32) throws -> String {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(fd, F_GETPATH, &pathBuf) == 0 else {
            throw WorkingCopyFileError.openFailed(errno)
        }
        var p = String(cString: pathBuf)
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private static func parseRelativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw WorkingCopyFileError.invalidPath
        }
        let rawParts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawParts.isEmpty else {
            throw WorkingCopyFileError.invalidPath
        }
        var components: [String] = []
        components.reserveCapacity(rawParts.count)
        for partSub in rawParts {
            let part = String(partSub)
            guard !part.isEmpty, part != ".", part != "..", part.lowercased() != ".svn" else {
                throw WorkingCopyFileError.invalidPath
            }
            components.append(part)
        }
        return components
    }

    private static func openVerifiedRootDirectory(_ rootPath: String) throws -> (fd: Int32, canonicalRoot: String) {
        guard !rootPath.isEmpty, !rootPath.contains("\0") else {
            throw WorkingCopyFileError.invalidPath
        }
        guard let cResolvedRoot = Darwin.realpath(rootPath, nil) else {
            throw WorkingCopyFileError.openFailed(errno)
        }
        defer { free(cResolvedRoot) }
        var resolvedRoot = String(cString: cResolvedRoot)
        while resolvedRoot.count > 1 && resolvedRoot.hasSuffix("/") {
            resolvedRoot.removeLast()
        }

        let dirFD = Darwin.open(resolvedRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else {
            throw WorkingCopyFileError.openFailed(errno)
        }
        do {
            let canonicalRoot = try getFDPath(dirFD)
            guard canonicalRoot == resolvedRoot else {
                Darwin.close(dirFD)
                throw WorkingCopyFileError.outsideRoot
            }
            return (dirFD, canonicalRoot)
        } catch {
            Darwin.close(dirFD)
            throw error
        }
    }

    private static func traverseParents(from rootFD: Int32, parents: ArraySlice<String>) throws -> Int32 {
        var dirFD = rootFD
        for comp in parents {
            let nextFD = Darwin.openat(dirFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFD >= 0 else {
                var openErr = errno
                if openErr == ENOTDIR {
                    var compSt = stat()
                    if Darwin.fstatat(dirFD, comp, &compSt, AT_SYMLINK_NOFOLLOW) == 0,
                       (compSt.st_mode & S_IFMT) == S_IFLNK {
                        openErr = ELOOP
                    }
                }
                Darwin.close(dirFD)
                throw WorkingCopyFileError.openFailed(openErr)
            }
            Darwin.close(dirFD)
            dirFD = nextFD
        }
        return dirFD
    }

    /// 打开工作副本根目录内的普通文件并返回已打开文件描述符与规范路径。
    /// 调用方须负责关闭 `fileDescriptor`（推荐使用 `withConfinedRegularFile`）。
    public static func openConfinedRegularFile(
        relativePath: String,
        inRoot rootPath: String
    ) throws -> ConfinedOpenResult {
        let components = try parseRelativeComponents(relativePath)
        let (rootFD, resolvedRoot) = try openVerifiedRootDirectory(rootPath)
        let parentFD = try traverseParents(from: rootFD, parents: components.dropLast())
        defer { Darwin.close(parentFD) }

        let leaf = components.last!
        let fileFD = Darwin.openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fileFD >= 0 else {
            throw WorkingCopyFileError.openFailed(errno)
        }

        var st = stat()
        guard Darwin.fstat(fileFD, &st) == 0 else {
            let err = errno
            Darwin.close(fileFD)
            throw WorkingCopyFileError.openFailed(err)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fileFD)
            throw WorkingCopyFileError.notRegularFile
        }
        guard st.st_nlink == 1 else {
            Darwin.close(fileFD)
            throw WorkingCopyFileError.hardLinked
        }

        let canonicalFilePath: String
        do {
            canonicalFilePath = try getFDPath(fileFD)
        } catch {
            Darwin.close(fileFD)
            throw error
        }
        let rootPrefix = resolvedRoot == "/" ? "/" : (resolvedRoot + "/")
        guard canonicalFilePath.hasPrefix(rootPrefix) else {
            Darwin.close(fileFD)
            throw WorkingCopyFileError.outsideRoot
        }

        return ConfinedOpenResult(
            fileDescriptor: fileFD,
            canonicalPath: canonicalFilePath,
            fileSize: Int64(st.st_size)
        )
    }

    /// 校验工作副本内普通文件或目录路径（拒绝 `..`、`.svn`、符号链接与跨目录硬链接），返回规范路径供 Finder 定位。
    public static func resolveConfinedPathForReveal(
        relativePath: String,
        inRoot rootPath: String
    ) throws -> String {
        if relativePath == "." {
            let (rootFD, canonicalRoot) = try openVerifiedRootDirectory(rootPath)
            Darwin.close(rootFD)
            return canonicalRoot
        }
        let components = try parseRelativeComponents(relativePath)
        let (rootFD, resolvedRoot) = try openVerifiedRootDirectory(rootPath)
        let parentFD = try traverseParents(from: rootFD, parents: components.dropLast())
        defer { Darwin.close(parentFD) }

        let leaf = components.last!
        let leafFD = Darwin.openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard leafFD >= 0 else {
            throw WorkingCopyFileError.openFailed(errno)
        }
        defer { Darwin.close(leafFD) }

        var st = stat()
        guard Darwin.fstat(leafFD, &st) == 0 else {
            throw WorkingCopyFileError.openFailed(errno)
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFREG {
            guard st.st_nlink == 1 else {
                throw WorkingCopyFileError.hardLinked
            }
        } else if fileType != S_IFDIR {
            throw WorkingCopyFileError.notRegularFile
        }

        let canonicalPath = try getFDPath(leafFD)
        let rootPrefix = resolvedRoot == "/" ? "/" : (resolvedRoot + "/")
        guard canonicalPath.hasPrefix(rootPrefix) else {
            throw WorkingCopyFileError.outsideRoot
        }
        return canonicalPath
    }

    public static func withConfinedRegularFile<T>(
        relativePath: String,
        inRoot rootPath: String,
        _ body: (ConfinedOpenResult) throws -> T
    ) throws -> T {
        let opened = try openConfinedRegularFile(relativePath: relativePath, inRoot: rootPath)
        defer { Darwin.close(opened.fileDescriptor) }
        return try body(opened)
    }
}
