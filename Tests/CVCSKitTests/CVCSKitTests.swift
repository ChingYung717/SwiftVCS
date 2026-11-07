import Foundation
import CVCSKit
import CSVNKit

@main
struct CVCSKitTests {
    static func main() async throws {
        testParseSingleFileUnifiedDiff()
        testParseMultiFileDiffDoesNotBleedHeadersIntoPreviousHunk()
        testWorkingCopyStatusPendingFlag()
        testKeychainScopeIncludesProtocolPortAndRepository()
        testMergeRevisionRange()
        testCompleteAndTruncatedText()
        try await testSequentialReconnectCredentialIsolation()
        try await testTruncatedWorkingCopyDiffPreservesSubsequentFiles()
        print("8 unit tests passed")
    }

    private static func testCompleteAndTruncatedText() {
        let chinese = Data("hello".utf8) + Data([0xD6, 0xD0])
        let invalidTail = Data("hello".utf8) + Data([0xE4])
        expect(SVNClient.decodeText(chinese) == "hello中")
        expect(SVNClient.decodeText(Data("UTF-8中文".utf8)) == "UTF-8中文")
        expect(SVNClient.decodeText(invalidTail) == nil)
        expect(SVNClient.decodeText(invalidTail, isTruncated: true) == "hello")
        expect(SVNClient.decodeText(Data([0])) == nil)
    }

    private static func expect(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) {
        guard condition else {
            FileHandle.standardError.write(Data("Assertion failed at \(file):\(line)\n".utf8))
            exit(1)
        }
    }

    private static func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) -> T {
        expect(value != nil, file: file, line: line)
        return value!
    }

    private static func testParseSingleFileUnifiedDiff() {
        let raw = """
        Index: /tmp/wc/src/main.txt
        ===================================================================
        --- /tmp/wc/src/main.txt\t(revision 2)
        +++ /tmp/wc/src/main.txt\t(working copy)
        @@ -1,2 +1,3 @@
         line1
        -old line2
        +new line2
        +added line3
        """
        let hunks = SVNClient.parseUnifiedDiff(raw)
        expect(hunks.count == 1)
        expect(hunks[0].oldStart == 1)
        expect(hunks[0].oldCount == 2)
        expect(hunks[0].newStart == 1)
        expect(hunks[0].newCount == 3)
        expect(hunks[0].lines.count == 4)
        expect(hunks[0].lines[0].kind == .context)
        expect(hunks[0].lines[1].kind == .deletion)
        expect(hunks[0].lines[2].kind == .addition)
        expect(hunks[0].lines[3].kind == .addition)
    }

    private static func testParseMultiFileDiffDoesNotBleedHeadersIntoPreviousHunk() {
        let raw = """
        Index: /tmp/wc/src/a.txt
        ===================================================================
        --- /tmp/wc/src/a.txt\t(revision 1)
        +++ /tmp/wc/src/a.txt\t(working copy)
        @@ -1 +1 @@
        -hello a
        +hello a modified
        Index: /tmp/wc/docs/b.txt
        ===================================================================
        --- /tmp/wc/docs/b.txt\t(revision 1)
        +++ /tmp/wc/docs/b.txt\t(working copy)
        @@ -1 +1,2 @@
         keep b
        +extra b
        """
        let diffs = SVNClient.parseMultiFileDiff(raw, workingCopyPath: "/tmp/wc", fallbackTarget: "/tmp/wc")
        expect(diffs.count == 2)
        expect(diffs[0].path == "src/a.txt")
        expect(diffs[0].addedCount == 1)
        expect(diffs[0].removedCount == 1)
        expect(diffs[1].path == "docs/b.txt")
        expect(diffs[1].addedCount == 1)
        expect(diffs[1].removedCount == 0)
    }

    private static func testWorkingCopyStatusPendingFlag() {
        expect(WorkingCopyStatus.Kind.modified.isPendingChange)
        expect(WorkingCopyStatus.Kind.added.isPendingChange)
        expect(WorkingCopyStatus.Kind.deleted.isPendingChange)
        expect(!WorkingCopyStatus.Kind.normal.isPendingChange)
        expect(!WorkingCopyStatus.Kind.unversioned.isPendingChange)
    }

    private static func testKeychainScopeIncludesProtocolPortAndRepository() {
        let first = require(URL(string: "https://example.invalid/svn/repo"))
        let normalized = require(URL(string: "https://EXAMPLE.invalid:443/svn/repo/"))
        let otherPort = require(URL(string: "https://example.invalid:8443/svn/repo"))
        let otherRepository = require(URL(string: "https://example.invalid/svn/other"))
        let insecure = require(URL(string: "http://example.invalid/svn/repo"))
        let embedded = require(URL(string: "https://user@example.invalid/svn/repo"))
        let scope = require(KeychainStore.service(for: first))
        expect(KeychainStore.service(for: normalized) == scope)
        expect(KeychainStore.service(for: otherPort) != scope)
        expect(KeychainStore.service(for: otherRepository) != scope)
        expect(KeychainStore.service(for: insecure) == nil)
        expect(KeychainStore.service(for: embedded) == nil)
    }

    private static func testMergeRevisionRange() {
        let source = require(URL(string: "https://example.invalid/repo/branches/feature"))
        let single = require(try? MergeRequest(source: source, revision: 1))
        expect(single.from == 0 && single.to == 1 && single.peg == 1)
        let range = require(try? MergeRequest(source: source, from: 2, to: 7, peg: 10))
        expect(range.from == 2 && range.to == 7 && range.peg == 10)
        expect((try? MergeRequest(source: source, revision: Int.min)) == nil)
        expect((try? MergeRequest(source: source, revision: Int(Int32.max) + 1)) == nil)
        expect((try? MergeRequest(source: source, from: 7, to: 2)) == nil)
        expect((try? MergeRequest(source: source, from: 2, to: 7, peg: 0)) == nil)
    }

    private static func findSVNTool(_ name: String) -> String {
        let candidates = [
            "/opt/homebrew/opt/subversion/bin/\(name)",
            "/usr/local/opt/subversion/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return name
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        expect(p.terminationStatus == 0)
    }

    private static func testSequentialReconnectCredentialIsolation() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-cred-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let svnadmin = findSVNTool("svnadmin")
        let svnserve = findSVNTool("svnserve")
        let repoA = tempRoot.appendingPathComponent("repoA")
        let repoB = tempRoot.appendingPathComponent("repoB")
        try runProcess(svnadmin, ["create", repoA.path])
        try runProcess(svnadmin, ["create", repoB.path])

        try """
        [general]
        anon-access = none
        auth-access = write
        password-db = passwd
        authz-db = authz
        realm = RepoA
        """.write(to: repoA.appendingPathComponent("conf/svnserve.conf"), atomically: true, encoding: .utf8)
        try """
        [users]
        alice = pwA
        bob = pwB
        """.write(to: repoA.appendingPathComponent("conf/passwd"), atomically: true, encoding: .utf8)
        try """
        [/]
        alice = rw
        """.write(to: repoA.appendingPathComponent("conf/authz"), atomically: true, encoding: .utf8)

        try """
        [general]
        anon-access = none
        auth-access = write
        password-db = passwd
        authz-db = authz
        realm = RepoB
        """.write(to: repoB.appendingPathComponent("conf/svnserve.conf"), atomically: true, encoding: .utf8)
        try """
        [users]
        alice = pwA
        bob = pwB
        """.write(to: repoB.appendingPathComponent("conf/passwd"), atomically: true, encoding: .utf8)
        try """
        [/]
        bob = rw
        """.write(to: repoB.appendingPathComponent("conf/authz"), atomically: true, encoding: .utf8)

        // Pick an ephemeral loopback port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        expect(sock >= 0)
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        expect(bindRC == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(sock)

        let logFile = tempRoot.appendingPathComponent("svnserve.log")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: svnserve)
        server.arguments = [
            "-d", "--foreground",
            "--listen-host", "127.0.0.1",
            "--listen-port", "\(port)",
            "-r", tempRoot.path,
            "--log-file", logFile.path
        ]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let urlA = require(URL(string: "svn://127.0.0.1:\(port)/repoA"))
        let urlB = require(URL(string: "svn://127.0.0.1:\(port)/repoB"))
        let configDir = tempRoot.appendingPathComponent("config")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let client = try SVNClient(
            username: "alice",
            password: "pwA",
            configDir: configDir.path,
            baseURL: urlA,
            useSavedCredentials: false
        )
        // 1. Connect to Repo A using initial alice credentials
        let infoA = try await client.connect(to: urlA, credentials: nil)
        expect(infoA.youngestRevision == 0)

        // 2. Explicitly connect to Repo B using bob credentials
        let bobCreds = Credentials(.usernamePassword(user: "bob", password: "pwB"))
        let infoB1 = try await client.connect(to: urlB, credentials: bobCreds)
        expect(infoB1.youngestRevision == 0)

        // 3. Reconnect to Repo B with credentials: nil -> must continue using bob, never alice
        let infoB2 = try await client.connect(to: urlB, credentials: nil)
        expect(infoB2.youngestRevision == 0)

        // 4. Switching back to Repo A with credentials: nil must not leak bob (nor silently resurrect alice)
        var repoARejectedWithoutCredentials = false
        do {
            _ = try await client.connect(to: urlA, credentials: nil)
        } catch {
            repoARejectedWithoutCredentials = true
        }
        expect(repoARejectedWithoutCredentials)
    }

    private static func testTruncatedWorkingCopyDiffPreservesSubsequentFiles() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-diffcap-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let svnadmin = findSVNTool("svnadmin")
        let repo = tempRoot.appendingPathComponent("repo")
        let wc = tempRoot.appendingPathComponent("wc")
        try runProcess(svnadmin, ["create", repo.path])

        let client = try SVNClient(useSavedCredentials: false)
        _ = try await client.connect(to: URL(fileURLWithPath: repo.path), credentials: nil)
        _ = try await client.checkout(path: nil, to: wc, revision: nil)

        let fileA = wc.appendingPathComponent("a.txt")
        let fileZ = wc.appendingPathComponent("z.txt")
        try "initial a\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "initial z\n".write(to: fileZ, atomically: true, encoding: .utf8)
        _ = try await client.add(workingCopy: wc, paths: ["a.txt", "z.txt"])
        _ = try await client.commit(workingCopy: wc, paths: [], message: "init", progress: nil)

        let largeLines = (1...200).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n") + "\n"
        try largeLines.write(to: fileA, atomically: true, encoding: .utf8)
        try "modified z line\n".write(to: fileZ, atomically: true, encoding: .utf8)

        let diffs = try await client.diff(workingCopy: wc, paths: [], maxBytes: 512)
        expect(diffs.count == 2)
        expect(diffs[0].path == "a.txt")
        expect(diffs[0].isTruncated)
        expect(diffs[1].path == "z.txt")
        expect(!diffs[1].isTruncated)
        expect(diffs[1].addedCount == 1)
    }
}
