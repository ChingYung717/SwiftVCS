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
        try await testKeychainReconnectPreservesRealmAndRejectsChangedRealm()
        try await testTruncatedWorkingCopyDiffPreservesSubsequentFiles()
        try await testTruncatedWorkingCopyDiffPreservesCopiedAndReplacedDirectories()
        print("10 unit tests passed")
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

    private static func testKeychainReconnectPreservesRealmAndRejectsChangedRealm() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-kcrealm-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let certFile = tempRoot.appendingPathComponent("server.crt")
        let keyFile = tempRoot.appendingPathComponent("server.key")
        let cnfFile = tempRoot.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=ext
        prompt=no
        [dn]
        CN=127.0.0.1
        [ext]
        subjectAltName=IP:127.0.0.1
        """.write(to: cnfFile, atomically: true, encoding: .utf8)
        try runProcess("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-config", cnfFile.path, "-days", "1",
            "-keyout", keyFile.path, "-out", certFile.path
        ])

        let realmFile = tempRoot.appendingPathComponent("realm.txt")
        let hitsFile = tempRoot.appendingPathComponent("hits.log")
        let portFile = tempRoot.appendingPathComponent("port.txt")
        let scriptFile = tempRoot.appendingPathComponent("server.py")
        try "RealmA".write(to: realmFile, atomically: true, encoding: .utf8)
        try "".write(to: hitsFile, atomically: true, encoding: .utf8)

        try """
        import base64, http.server, pathlib, ssl, sys, threading

        cert, key, realm_path, hits_path, port_path = sys.argv[1:6]
        expected_auth = "Basic " + base64.b64encode(b"alice:pwA").decode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def do_OPTIONS(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length:
                    self.rfile.read(length)
                realm = pathlib.Path(realm_path).read_text().strip()
                auth = self.headers.get("Authorization")
                has_auth = "1" if auth else "0"
                with open(hits_path, "a", encoding="utf-8") as f:
                    f.write(f"{realm}\\t{has_auth}\\n")
                if realm != "ANON" and auth != expected_auth:
                    self.send_response(401)
                    self.send_header("WWW-Authenticate", f'Basic realm="{realm}"')
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                body = (
                    b'<?xml version="1.0" encoding="utf-8"?>'
                    b'<D:options-response xmlns:D="DAV:">'
                    b'<D:activity-collection-set><D:href>/repo/!svn/act/</D:href></D:activity-collection-set>'
                    b'</D:options-response>'
                )
                self.send_response(200)
                self.send_header("DAV", "1,2")
                self.send_header("DAV", "version-control,checkout,working-resource")
                self.send_header("DAV", "merge,baseline,activity,version-controlled-collection")
                self.send_header("DAV", "http://subversion.tigris.org/xmlns/dav/svn/depth")
                self.send_header("DAV", "http://subversion.tigris.org/xmlns/dav/svn/log-revprops")
                self.send_header("DAV", "http://subversion.tigris.org/xmlns/dav/svn/atomic-revprops")
                self.send_header("DAV", "http://subversion.tigris.org/xmlns/dav/svn/partial-replay")
                self.send_header("DAV", "http://subversion.tigris.org/xmlns/dav/svn/mergeinfo")
                self.send_header("SVN-Youngest-Rev", "3")
                self.send_header("SVN-Repository-UUID", "11111111-2222-3333-4444-555555555555")
                self.send_header("SVN-Repository-Root", "/repo")
                self.send_header("SVN-Me-Resource", "/repo/!svn/me")
                self.send_header("SVN-Rev-Root-Stub", "/repo/!svn/rvr")
                self.send_header("SVN-Rev-Stub", "/repo/!svn/rev")
                self.send_header("SVN-Txn-Root-Stub", "/repo/!svn/txr")
                self.send_header("SVN-Txn-Stub", "/repo/!svn/txn")
                self.send_header("SVN-VTxn-Root-Stub", "/repo/!svn/vtxr")
                self.send_header("SVN-VTxn-Stub", "/repo/!svn/vtxn")
                self.send_header("Content-Type", 'text/xml; charset="utf-8"')
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        srv.socket = tls.wrap_socket(srv.socket, server_side=True)
        pathlib.Path(port_path).write_text(str(srv.server_port))
        srv.serve_forever()
        """.write(to: scriptFile, atomically: true, encoding: .utf8)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [scriptFile.path, certFile.path, keyFile.path, realmFile.path, hitsFile.path, portFile.path]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }

        var portString = ""
        for _ in 0..<50 {
            if let s = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                portString = s
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let port = require(Int(portString))
        let url = require(URL(string: "https://127.0.0.1:\(port)/repo"))
        let otherURL = require(URL(string: "https://127.0.0.1:\(port)/other"))
        let service = require(KeychainStore.service(for: url))
        let configDir = tempRoot.appendingPathComponent("config")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let probed = try TrustStore.shared.probeCertificate(host: "127.0.0.1", port: port)
        try TrustStore.shared.trust(probed, for: url)
        defer {
            try? TrustStore.shared.removeCertificate(name: "127.0.0.1:\(port)")
            try? KeychainStore.delete(url: url, username: "alice")
        }

        // 1. Authenticate with username/password against RealmA and persist to Keychain
        // Also verify that a failed connect to otherURL does not bind unbound init credentials to otherURL
        let seedClient = try SVNClient(username: "alice", password: "pwA", configDir: configDir.path, useSavedCredentials: false)
        var failedOtherConnect = false
        do {
            _ = try await seedClient.connect(
                to: otherURL,
                credentials: Credentials(.keychain(service: "missing.service", account: "bob"))
            )
        } catch VCSError.authenticationFailed {
            failedOtherConnect = true
        }
        expect(failedOtherConnect)
        let seedInfo = try await seedClient.connect(to: url, credentials: nil)
        expect(seedInfo.youngestRevision == 3)
        let remembered = try await seedClient.rememberPassword()
        expect(remembered)

        // 2. Connect using .keychain credentials, then reconnect with credentials: nil under same RealmA
        let kcClient = try SVNClient(configDir: configDir.path, useSavedCredentials: true)
        let kcInfo1 = try await kcClient.connect(
            to: url,
            credentials: Credentials(.keychain(service: service, account: "alice"))
        )
        expect(kcInfo1.youngestRevision == 3)
        let kcInfo2 = try await kcClient.connect(to: url, credentials: nil)
        expect(kcInfo2.youngestRevision == 3)

        // 3. Also verify auto-loaded Keychain credentials via init(username:baseURL:useSavedCredentials:true)
        let autoClient = try SVNClient(
            username: "alice",
            configDir: configDir.path,
            baseURL: url,
            useSavedCredentials: true
        )
        let autoInfo1 = try await autoClient.connect(to: url, credentials: nil)
        expect(autoInfo1.youngestRevision == 3)
        let autoInfo2 = try await autoClient.connect(to: url, credentials: nil)
        expect(autoInfo2.youngestRevision == 3)

        // 3b. Also verify Keychain connect when initial OPTIONS does not challenge (anonymous),
        // so csvn_auth_realm is empty and candidate.realm from Keychain must still be preserved
        try "ANON".write(to: realmFile, atomically: true, encoding: .utf8)
        let anonKCClient = try SVNClient(configDir: configDir.path, useSavedCredentials: true)
        let anonInfo = try await anonKCClient.connect(
            to: url,
            credentials: Credentials(.keychain(service: service, account: "alice"))
        )
        expect(anonInfo.youngestRevision == 3)

        // 4. Switch the server at the same URL to RealmB; reconnecting with credentials: nil must NOT send password
        try "".write(to: hitsFile, atomically: true, encoding: .utf8)
        try "RealmB".write(to: realmFile, atomically: true, encoding: .utf8)

        var kcRejectedOnRealmChange = false
        do {
            _ = try await kcClient.connect(to: url, credentials: nil)
        } catch VCSError.authenticationFailed {
            kcRejectedOnRealmChange = true
        }
        expect(kcRejectedOnRealmChange)

        var autoRejectedOnRealmChange = false
        do {
            _ = try await autoClient.connect(to: url, credentials: nil)
        } catch VCSError.authenticationFailed {
            autoRejectedOnRealmChange = true
        }
        expect(autoRejectedOnRealmChange)

        var anonKCRejectedOnRealmChange = false
        do {
            _ = try await anonKCClient.connect(to: url, credentials: nil)
        } catch VCSError.authenticationFailed {
            anonKCRejectedOnRealmChange = true
        }
        expect(anonKCRejectedOnRealmChange)

        let hitsAfterChange = try String(contentsOf: hitsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        expect(!hitsAfterChange.isEmpty)
        expect(hitsAfterChange.allSatisfy { $0 == "RealmB\t0" })
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

        // Verify that passing multiple child targets followed by their ancestor "." merges all descendant groups without duplicating hunks
        let mergedDiffs = try await client.diff(workingCopy: wc, paths: ["a.txt", "z.txt", "."], maxBytes: 512)
        expect(mergedDiffs.count == 2)
        expect(mergedDiffs[1].path == "z.txt")
        expect(mergedDiffs[1].hunks.count == 1)
        expect(mergedDiffs[1].addedCount == 1)
    }

    private static func testTruncatedWorkingCopyDiffPreservesCopiedAndReplacedDirectories() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-dirdiff-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let svnadmin = findSVNTool("svnadmin")
        let svn = findSVNTool("svn")
        let repo = tempRoot.appendingPathComponent("repo")
        let wc = tempRoot.appendingPathComponent("wc")
        try runProcess(svnadmin, ["create", repo.path])

        let client = try SVNClient(useSavedCredentials: false)
        _ = try await client.connect(to: URL(fileURLWithPath: repo.path), credentials: nil)
        _ = try await client.checkout(path: nil, to: wc, revision: nil)

        let fileA = wc.appendingPathComponent("a.txt")
        let srcDir = wc.appendingPathComponent("src_dir")
        let srcSubDir = srcDir.appendingPathComponent("only_in_src")
        let otherDir = wc.appendingPathComponent("other_dir")
        let repDir = wc.appendingPathComponent("rep_dir")
        let repCopyDir = wc.appendingPathComponent("rep_copy_dir")
        try fm.createDirectory(at: srcSubDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repCopyDir, withIntermediateDirectories: true)
        try "initial a\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "unchanged copied line\n".write(to: srcDir.appendingPathComponent("unchanged.txt"), atomically: true, encoding: .utf8)
        try "copied base line\n".write(to: srcDir.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try "src sub line\n".write(to: srcSubDir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try "other sub line\n".write(to: otherDir.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        try "deleted old line\n".write(to: repDir.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let mediumOld = (1...8).map { "old rep line \($0) " + String(repeating: "d", count: 20) }.joined(separator: "\n") + "\n"
        try mediumOld.write(to: repDir.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "deleted rep_copy old\n".write(to: repCopyDir.appendingPathComponent("prior.txt"), atomically: true, encoding: .utf8)

        _ = try await client.add(workingCopy: wc, paths: ["a.txt", "src_dir", "other_dir", "rep_dir", "rep_copy_dir"])
        _ = try await client.commit(workingCopy: wc, paths: [], message: "r1", progress: nil)
        _ = try await client.update(workingCopy: wc, revision: nil, progress: nil)

        // 1. Oversized file edit to trigger maxBytes cap, plus an added empty file
        let largeLines = (1...200).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n") + "\n"
        try largeLines.write(to: fileA, atomically: true, encoding: .utf8)
        let emptyFile = wc.appendingPathComponent("empty.txt")
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        _ = try await client.add(workingCopy: wc, paths: ["empty.txt"])

        // 2. Copy directory: unchanged.txt has status .normal, modified.txt has status .modified
        try runProcess(svn, ["copy", wc.appendingPathComponent("src_dir").path, wc.appendingPathComponent("copied_dir").path])
        try "copied base line\nextra line\n".write(
            to: wc.appendingPathComponent("copied_dir/modified.txt"),
            atomically: true,
            encoding: .utf8
        )

        // 3. Replace directory: old.txt is deleted, new.txt is added, same.txt is both deleted and added (exceeding 512 bytes combined)
        try runProcess(svn, ["rm", wc.appendingPathComponent("rep_dir").path])
        try runProcess(svn, ["mkdir", wc.appendingPathComponent("rep_dir").path])
        try "added new line\n".write(to: repDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let mediumNew = (1...8).map { "new rep line \($0) " + String(repeating: "a", count: 20) }.joined(separator: "\n") + "\n"
        try mediumNew.write(to: repDir.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        _ = try await client.add(workingCopy: wc, paths: ["rep_dir/new.txt", "rep_dir/same.txt"])

        // 4. Nested directory replacement-by-copy: replace rep_copy_dir with src_dir, then replace rep_copy_dir/only_in_src with other_dir
        try runProcess(svn, ["rm", repCopyDir.path])
        try runProcess(svn, ["copy", srcDir.path, repCopyDir.path])
        try runProcess(svn, ["rm", "--force", repCopyDir.appendingPathComponent("only_in_src").path])
        try runProcess(svn, ["copy", otherDir.path, repCopyDir.appendingPathComponent("only_in_src").path])

        let unlimited = try await client.diff(workingCopy: wc, paths: [], maxBytes: 0)
        let capped = try await client.diff(workingCopy: wc, paths: [], maxBytes: 512)

        expect(capped.map(\.path) == unlimited.map(\.path))
        expect(!capped.contains { $0.path == "empty.txt" })
        let byPath = Dictionary(uniqueKeysWithValues: capped.map { ($0.path, $0) })

        let diffA = require(byPath["a.txt"])
        expect(diffA.isTruncated)

        let diffUnchanged = require(byPath["copied_dir/unchanged.txt"])
        expect(!diffUnchanged.isTruncated)
        expect(diffUnchanged.addedCount == 1 && diffUnchanged.removedCount == 0)

        let diffModified = require(byPath["copied_dir/modified.txt"])
        expect(!diffModified.isTruncated)
        expect(diffModified.addedCount == 2 && diffModified.removedCount == 0)

        let diffOld = require(byPath["rep_dir/old.txt"])
        expect(!diffOld.isTruncated)
        expect(diffOld.removedCount == 1 && diffOld.addedCount == 0)

        let diffNew = require(byPath["rep_dir/new.txt"])
        expect(!diffNew.isTruncated)
        expect(diffNew.addedCount == 1 && diffNew.removedCount == 0)

        // Replaced file with two Index: sections whose combined length > 512 bytes must be marked truncated
        let diffSame = require(byPath["rep_dir/same.txt"])
        expect(diffSame.isTruncated)

        // Nested replacement-by-copy diffs
        let diffPrior = require(byPath["rep_copy_dir/prior.txt"])
        expect(!diffPrior.isTruncated)
        expect(diffPrior.removedCount == 1 && diffPrior.addedCount == 0)

        let diffNestedReplaced = require(byPath["rep_copy_dir/only_in_src/o.txt"])
        expect(!diffNestedReplaced.isTruncated)
        expect(diffNestedReplaced.addedCount == 1 && diffNestedReplaced.removedCount == 0)

        // Even under a tiny cap smaller than the 2-line Index:/=== header, added empty file is not emitted as a truncated diff
        let tinyCapEmpty = try await client.diff(workingCopy: wc, paths: ["empty.txt"], maxBytes: 32)
        expect(tinyCapEmpty.isEmpty)

        // Also verify targeted child path diffing inside copied and replaced directories
        let targeted = try await client.diff(
            workingCopy: wc,
            paths: ["copied_dir/unchanged.txt", "rep_dir/old.txt", "rep_copy_dir/only_in_src/o.txt"],
            maxBytes: 512
        )
        expect(targeted.map(\.path) == ["copied_dir/unchanged.txt", "rep_dir/old.txt", "rep_copy_dir/only_in_src/o.txt"])
        expect(targeted[0].addedCount == 1 && targeted[0].removedCount == 0)
        expect(targeted[1].removedCount == 1 && targeted[1].addedCount == 0)
        expect(targeted[2].addedCount == 1 && targeted[2].removedCount == 0)
    }
}
