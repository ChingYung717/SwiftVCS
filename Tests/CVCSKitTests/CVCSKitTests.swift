import Foundation
import CVCSKit
import CSVNKit
import CSVNShim

@main
struct CVCSKitTests {
    static func main() async throws {
        testParseSingleFileUnifiedDiff()
        testParseMultiFileDiffDoesNotBleedHeadersIntoPreviousHunk()
        testWorkingCopyStatusPendingFlag()
        testKeychainScopeIncludesProtocolPortAndRepository()
        testMergeRevisionRange()
        testCompleteAndTruncatedText()
        try testURLSanitizerAndSettingsMigration()
        try await testCBufferContractsAndRevisionBounds()
        try await testBoundedDiffAndCancellation()
        try await testSequentialReconnectCredentialIsolation()
        try await testKeychainReconnectPreservesRealmAndRejectsChangedRealm()
        try await testTruncatedWorkingCopyDiffPreservesSubsequentFiles()
        try await testTruncatedWorkingCopyDiffPreservesCopiedAndReplacedDirectories()
        print("13 unit tests passed")
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

    private static func findSVNTool(_ name: String, file: StaticString = #fileID, line: UInt = #line) -> String {
        var candidates = [
            "/opt/homebrew/opt/subversion/bin/\(name)",
            "/usr/local/opt/subversion/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") where dir.hasPrefix("/") {
                let candidate = "\(dir)/\(name)"
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        FileHandle.standardError.write(
            Data("Required SVN tool '\(name)' not found in candidates: \(candidates.joined(separator: ", "))\n".utf8)
        )
        expect(false, file: file, line: line)
        return ""
    }

    private static func spawnBackgroundProcess(
        _ executable: String,
        _ arguments: [String],
        stderrPath: String = "/dev/null",
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> pid_t {
        expect(executable.hasPrefix("/"), file: file, line: line)
        var fileActions: posix_spawn_file_actions_t?
        expect(posix_spawn_file_actions_init(&fileActions) == 0, file: file, line: line)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        expect(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0, file: file, line: line)
        expect(posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0, file: file, line: line)
        let errFlags = stderrPath == "/dev/null" ? O_WRONLY : (O_WRONLY | O_CREAT | O_TRUNC)
        expect(
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, stderrPath, errFlags, 0o600) == 0,
            file: file,
            line: line
        )

        let argvStrings = [executable] + arguments
        let cArgs = argvStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgs where ptr != nil {
                free(ptr)
            }
        }
        expect(cArgs.dropLast().allSatisfy { $0 != nil }, file: file, line: line)
        var pid: pid_t = 0
        let rc = cArgs.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, executable, &fileActions, nil, buf.baseAddress, environ)
        }
        if rc != 0 {
            let errMsg = String(cString: strerror(rc))
            FileHandle.standardError.write(
                Data("posix_spawn failed for \(executable) \(arguments.joined(separator: " ")): rc=\(rc) (\(errMsg))\n".utf8)
            )
        }
        expect(rc == 0, file: file, line: line)
        return pid
    }

    private static func stopBackgroundProcess(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = kill(pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<25 {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited == -1 && errno == ECHILD) {
                return
            }
            usleep(10_000)
        }
        _ = kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    private static func assertBackgroundProcessAlive(
        _ pid: pid_t,
        stderrFile: URL,
        label: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        if waited != 0 {
            let stderrText = (try? String(contentsOf: stderrFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            FileHandle.standardError.write(
                Data("Background process '\(label)' (pid=\(pid)) exited prematurely (waited=\(waited), status=\(status)): stderr=\(stderrText)\n".utf8)
            )
            expect(false, file: file, line: line)
        }
    }

    private static func waitForBackgroundPort(
        _ pid: pid_t,
        portFile: URL,
        stderrFile: URL,
        label: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async throws -> Int {
        for _ in 0..<50 {
            if let s = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let port = Int(s), port > 0 {
                return port
            }
            assertBackgroundProcessAlive(pid, stderrFile: stderrFile, label: label, file: file, line: line)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let stderrText = (try? String(contentsOf: stderrFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        FileHandle.standardError.write(
            Data("Timed out waiting for background process '\(label)' (pid=\(pid)) port file (\(portFile.path)): stderr=\(stderrText)\n".utf8)
        )
        expect(false, file: file, line: line)
        return 0
    }

    private static func runProcess(
        _ executable: String,
        _ arguments: [String],
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws {
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftvcs-proc-\(UUID().uuidString).err")
        defer { try? FileManager.default.removeItem(at: errFile) }
        let pid = try spawnBackgroundProcess(executable, arguments, stderrPath: errFile.path, file: file, line: line)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        let exitedNormally = signal == 0
        let exitCode = (status >> 8) & 0xff
        if !exitedNormally || exitCode != 0 {
            let stderrText = (try? String(contentsOf: errFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            FileHandle.standardError.write(
                Data("Command failed (\(executable) \(arguments.joined(separator: " "))): exitedNormally=\(exitedNormally) exitCode=\(exitCode) signal=\(signal) stderr=\(stderrText)\n".utf8)
            )
        }
        expect(exitedNormally && exitCode == 0, file: file, line: line)
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
        let errFile = tempRoot.appendingPathComponent("svnserve.err")
        let serverPID = try spawnBackgroundProcess(svnserve, [
            "-d", "--foreground",
            "--listen-host", "127.0.0.1",
            "--listen-port", "\(port)",
            "-r", tempRoot.path,
            "--log-file", logFile.path
        ], stderrPath: errFile.path)
        defer {
            stopBackgroundProcess(serverPID)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        assertBackgroundProcessAlive(serverPID, stderrFile: errFile, label: "svnserve")

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

        let serverErrFile = tempRoot.appendingPathComponent("tls-server.err")
        let serverPID = try spawnBackgroundProcess("/usr/bin/python3", [
            scriptFile.path, certFile.path, keyFile.path, realmFile.path, hitsFile.path, portFile.path
        ], stderrPath: serverErrFile.path)
        defer {
            stopBackgroundProcess(serverPID)
        }

        let port = try await waitForBackgroundPort(
            serverPID,
            portFile: portFile,
            stderrFile: serverErrFile,
            label: "tls-server"
        )
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

    private static func testURLSanitizerAndSettingsMigration() throws {
        // 1. SV-01 URL Matrix
        expect(SVNURLSanitizer.sanitizeForPersistence("https://user:pass@host.example/repo") == "https://host.example/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("https://user@host.example/repo") == "https://host.example/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("http://user:pass@host.example:8080/repo/") == "http://host.example:8080/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("svn://user:pass@host.example:3690/repo") == "svn://host.example:3690/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("svn+ssh://deploy@host.example/repo") == "svn+ssh://deploy@host.example/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("svn+ssh://deploy:secret@host.example/repo") == "svn+ssh://deploy@host.example/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("https://user:p%40ss@host.example/repo") == "https://host.example/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("svn+ssh://deploy:p%40ss@host.example:2222/repo/") == "svn+ssh://deploy@host.example:2222/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("https://user:p@ss@host.example/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("svn+ssh://:secret@host.example/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://[2001:db8::1]:8443/svn/repo/") == "https://[2001:db8::1]:8443/svn/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("https://alice:secret@[2001:db8::1]:8443/svn/repo/") == "https://[2001:db8::1]:8443/svn/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("file:///var/svn/repo") == "file:///var/svn/repo")
        expect(SVNURLSanitizer.sanitizeForPersistence("   ") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("ftp://user:pass@host.example/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://alice:1234/secretPass@svn.example.com/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://alice/secretPass@svn.example.com/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://alice:Pass?123#@svn.example.com/repo") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://svn.example.com/repo%00evil") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("https://svn.example.com/repo%0Aevil") == nil)
        expect(SVNURLSanitizer.sanitizeForPersistence("svn+ssh://bad%ZZuser@svn.example.com/repo") == nil)

        // Display redaction preserves non-sensitive display while never leaking passwords
        expect(SVNURLSanitizer.redactForDisplay("https://alice:secret123@host.example/repo") == "https://host.example/repo")
        expect(SVNURLSanitizer.redactForDisplay("svn+ssh://deploy:secret123@host.example/repo") == "svn+ssh://deploy@host.example/repo")
        let malformedRedacted = SVNURLSanitizer.redactForDisplay("https://alice:p@ss@host.example/repo")
        expect(!malformedRedacted.contains("p@ss") && !malformedRedacted.contains("alice"))
        let slashPassRedacted = SVNURLSanitizer.redactForDisplay("https://alice:1234/secretSlash@host.example/repo")
        expect(!slashPassRedacted.contains("secretSlash") && !slashPassRedacted.contains("1234"))
        let queryPassRedacted = SVNURLSanitizer.redactForDisplay("https://alice:P@ss?123#@host.example/repo")
        expect(!queryPassRedacted.contains("P@ss") && !queryPassRedacted.contains("123#"))
        let noSchemeRedacted = SVNURLSanitizer.redactCredentials(inMessage: "auth failed for user:p@ss?word#1@host.example/repo")
        expect(!noSchemeRedacted.contains("p@ss") && !noSchemeRedacted.contains("word#1"))
        // Legitimate host:port with @peg revision must not be falsely redacted
        let pegURL = "https://svn.example.com:8443/repo/trunk/file.txt@123"
        expect(SVNURLSanitizer.redactCredentials(inMessage: pegURL) == pegURL)

        // Error message redaction
        let dirtyErr = "ra_serf: connection failed to 'https://alice:topSecret99!@svn.example.com:8443/repo/trunk' and 'svn+ssh://bob:sshPass!@svn.example.com/repo'"
        let cleanErr = SVNURLSanitizer.redactCredentials(inMessage: dirtyErr)
        expect(!cleanErr.contains("topSecret99!"))
        expect(!cleanErr.contains("sshPass!"))
        expect(cleanErr.contains("https://<redacted>@svn.example.com:8443/repo/trunk"))
        expect(cleanErr.contains("svn+ssh://<redacted>@svn.example.com/repo"))

        // 2. Settings persistence: initial creation, replacement, legacy migration, lifecycle & permissions
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("swiftvcs-settings-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }
        let nestedDir = tempDir.appendingPathComponent("config/vcs-explorer")
        let settingsFile = nestedDir.appendingPathComponent("settings.json")

        let secret1 = "firstSecret_SV01"
        let secret2 = "sshSecret_SV01"
        let secret3 = "secondSecret_SV01"
        let secret4 = "legacyPass123_SV01"
        let secret5 = "sshKeyPass_SV01"
        let secret6 = "slashPass_SV01"
        let allSecrets = [secret1, secret2, secret3, secret4, secret5, secret6]
        func assertNoSecrets(in text: String) {
            for s in allSecrets {
                expect(!text.contains(s))
            }
        }

        // 2a. First-time creation when directory & settings.json do not exist yet
        var firstSettings = AppSettings(
            repoURL: "https://alice:\(secret1)@svn.example.com/repoA",
            username: "alice",
            workingCopyPath: "/tmp/wcA",
            recentRepos: [
                "https://alice:\(secret1)@svn.example.com/repoA",
                "svn+ssh://deploy:\(secret2)@svn.example.com/repoB",
                "https://alice:1234/\(secret6)@svn.example.com/repoSlash"
            ]
        )
        try AppSettingsStore.saveThrowing(firstSettings, to: settingsFile)
        expect(fm.fileExists(atPath: settingsFile.path))

        let dirPerms = try fm.attributesOfItem(atPath: nestedDir.path)[.posixPermissions] as? Int
        let filePerms1 = try fm.attributesOfItem(atPath: settingsFile.path)[.posixPermissions] as? Int
        expect(dirPerms == 0o700)
        expect(filePerms1 == 0o600)

        let rawSaved1 = try String(contentsOf: settingsFile, encoding: .utf8)
        assertNoSecrets(in: rawSaved1)
        expect(rawSaved1.contains("https://svn.example.com/repoA") || rawSaved1.contains("https:\\/\\/svn.example.com\\/repoA"))
        expect(rawSaved1.contains("deploy@svn.example.com"))

        // 2b. Lifecycle simulation: connection rejected/failed -> open working copy -> refresh -> remove association -> restart (load)
        // Step 1: rejected malformed URL does not overwrite valid repoURL with secret
        firstSettings.repoURL = "https://bob:p@ss:\(secret3)@svn.example.com/repoRejected"
        firstSettings.recentRepos.insert(firstSettings.repoURL, at: 0)
        try AppSettingsStore.saveThrowing(firstSettings, to: settingsFile)
        assertNoSecrets(in: try String(contentsOf: settingsFile, encoding: .utf8))

        // Step 2: open working copy & refresh with embedded credentials in URL
        firstSettings.repoURL = "https://bob:\(secret3)@svn.example.com/repoC"
        firstSettings.workingCopyPath = "/tmp/wcC"
        firstSettings.recentRepos.insert(firstSettings.repoURL, at: 0)
        try AppSettingsStore.saveThrowing(firstSettings, to: settingsFile)
        let filePerms2 = try fm.attributesOfItem(atPath: settingsFile.path)[.posixPermissions] as? Int
        expect(filePerms2 == 0o600)
        let rawSaved2 = try String(contentsOf: settingsFile, encoding: .utf8)
        assertNoSecrets(in: rawSaved2)
        expect(rawSaved2.contains("repoC"))

        // Step 3: remove working copy association & restart (reload from disk)
        firstSettings.workingCopyPath = ""
        try AppSettingsStore.saveThrowing(firstSettings, to: settingsFile)
        let reloadedAfterClear = AppSettingsStore.load(from: settingsFile)
        expect(reloadedAfterClear.workingCopyPath.isEmpty)
        expect(reloadedAfterClear.repoURL == "https://svn.example.com/repoC")
        for recent in reloadedAfterClear.recentRepos {
            assertNoSecrets(in: recent)
            assertNoSecrets(in: SVNURLSanitizer.redactForDisplay(recent))
        }

        // 2c. Legacy dirty file migration on load() rewrites disk immediately and deduplicates
        let legacyJSON = """
        {
          "repoURL": "https://legacyUser:\(secret4)@svn.example.com:8443/legacyRepo",
          "username": "legacyUser",
          "workingCopyPath": "/tmp/wc",
          "recentRepos": [
            "https://legacyUser:\(secret4)@svn.example.com:8443/legacyRepo",
            "https://otherUser@svn.example.com:8443/legacyRepo",
            "svn+ssh://git:\(secret5)@svn.example.com/sshRepo",
            "https://broken:unencoded@at@svn.example.com/badRepo",
            "https://alice:1234/\(secret6)@svn.example.com/badSlashRepo"
          ]
        }
        """
        try legacyJSON.write(to: settingsFile, atomically: true, encoding: .utf8)
        let migrated = AppSettingsStore.load(from: settingsFile)
        expect(migrated.repoURL == "https://svn.example.com:8443/legacyRepo")
        expect(migrated.recentRepos == [
            "https://svn.example.com:8443/legacyRepo",
            "svn+ssh://git@svn.example.com/sshRepo"
        ])

        let rewrittenDisk = try String(contentsOf: settingsFile, encoding: .utf8)
        assertNoSecrets(in: rewrittenDisk)
        expect(!rewrittenDisk.contains("otherUser@"))
        expect(!rewrittenDisk.contains("broken:unencoded"))
        let filePerms3 = try fm.attributesOfItem(atPath: settingsFile.path)[.posixPermissions] as? Int
        expect(filePerms3 == 0o600)
    }

    private static func testCBufferContractsAndRevisionBounds() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-cbuf-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let svnadmin = findSVNTool("svnadmin")
        let repo = tempRoot.appendingPathComponent("repo")
        try runProcess(svnadmin, ["create", repo.path])
        let repoURL = URL(fileURLWithPath: repo.path).absoluteString

        var errBuf = [CChar](repeating: 0, count: 256)
        guard let ctx = csvn_context_create(nil, nil, nil, nil, nil, nil, nil, nil, &errBuf, 256) else {
            expect(false)
            return
        }
        defer { csvn_context_destroy(ctx) }

        // 1. SV-04: Invalid buffer parameters must fail with -100 immediately before touching network/repo
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        expect(listenFD >= 0)
        defer {
            if listenFD >= 0 {
                close(listenFD)
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        expect(bindRC == 0)
        expect(listen(listenFD, 4) == 0)
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &boundLen)
            }
        }
        let listenPort = Int(UInt16(bigEndian: addr.sin_port))
        let probeURL = "http://127.0.0.1:\(listenPort)/svn/repo"

        var rev: Int32 = -1
        let rcNullBuf = probeURL.withCString { u in
            csvn_connect(ctx, u, nil, 64, &rev)
        }
        expect(rcNullBuf == -100)

        var sentinel = [CChar](repeating: 0x5A, count: 16)
        let rcZeroLen = probeURL.withCString { u in
            sentinel.withUnsafeMutableBufferPointer { buf in
                csvn_connect(ctx, u, buf.baseAddress, 0, &rev)
            }
        }
        expect(rcZeroLen == -100)
        expect(sentinel.allSatisfy { $0 == 0x5A })

        let rcNegLen = probeURL.withCString { u in
            sentinel.withUnsafeMutableBufferPointer { buf in
                csvn_connect(ctx, u, buf.baseAddress, -5, &rev)
            }
        }
        expect(rcNegLen == -100)
        expect(sentinel.allSatisfy { $0 == 0x5A })

        // Verify zero TCP connections were initiated by invalid buffer calls
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let pollRC = poll(&pfd, 1, 0)
        expect(pollRC == 0)

        // Length 1 buffer: must succeed, write NUL at index 0, and leave index 1 untouched
        let rcLen1 = repoURL.withCString { u in
            sentinel.withUnsafeMutableBufferPointer { buf in
                csvn_connect(ctx, u, buf.baseAddress, 1, &rev)
            }
        }
        expect(rcLen1 == 0)
        expect(sentinel[0] == 0)
        expect(sentinel[1] == 0x5A)

        // Small buffer (8 bytes): must truncate UUID to 7 chars + NUL at index 7, leaving index 8 untouched
        sentinel = [CChar](repeating: 0x5A, count: 16)
        let rcLen8 = repoURL.withCString { u in
            sentinel.withUnsafeMutableBufferPointer { buf in
                csvn_connect(ctx, u, buf.baseAddress, 8, &rev)
            }
        }
        expect(rcLen8 == 0)
        expect(sentinel[7] == 0)
        expect(sentinel[8] == 0x5A)
        expect(strlen(sentinel) == 7)

        // Normal buffer (64 bytes): must write full 36-char UUID + NUL without touching byte 64
        var fullUUID = [CChar](repeating: 0x5A, count: 65)
        let rcFull = repoURL.withCString { u in
            fullUUID.withUnsafeMutableBufferPointer { buf in
                csvn_connect(ctx, u, buf.baseAddress, 64, &rev)
            }
        }
        expect(rcFull == 0)
        expect(strlen(fullUUID) == 36)
        expect(fullUUID[36] == 0)
        expect(fullUUID[63] == 0)
        expect(fullUUID[64] == 0x5A)

        // 2. SV-11 & SV-01: Revision bounds > Int32.max and embedded URL credentials must be rejected
        let client = try SVNClient(useSavedCredentials: false)
        _ = try await client.connect(to: URL(fileURLWithPath: repo.path), credentials: nil)
        let overflowRev = Int(Int32.max) + 1

        var catRejected = false
        do {
            _ = try await client.cat(path: "nonexistent.txt", revision: overflowRev)
        } catch VCSError.invalidArgument {
            catRejected = true
        }
        expect(catRejected)

        var copyFromRejected = false
        do {
            let badChange = ChangedPath(
                action: .added,
                path: "/trunk/a.txt",
                kind: .file,
                copyFromPath: "/trunk/old.txt",
                copyFromRevision: overflowRev
            )
            _ = try await client.diffFile(revision: 1, change: badChange)
        } catch VCSError.invalidArgument {
            copyFromRejected = true
        }
        expect(copyFromRejected)

        var logCredRejected = false
        do {
            _ = try await client.log(
                workingCopy: URL(string: "https://alice:EmbeddedSecret99@svn.example.com/repo")!,
                path: nil,
                limit: 10,
                startRevision: nil
            )
        } catch VCSError.invalidArgument {
            logCredRejected = true
        }
        expect(logCredRejected)

        // 3. SV-13: Error redaction in C layer (csvn_last_error) and Swift layer
        let badCredURL = "https://baduser:UltraSecretPass789@127.0.0.1:1/svn/repo"
        var uuidBuf = [CChar](repeating: 0, count: 64)
        let rcFail = badCredURL.withCString { u in
            csvn_connect(ctx, u, &uuidBuf, 64, &rev)
        }
        expect(rcFail != 0)
        if let cErr = csvn_last_error(ctx) {
            let errStr = String(cString: cErr)
            expect(!errStr.contains("UltraSecretPass789"))
        }
    }

    private static func testBoundedDiffAndCancellation() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftvcs-boundeddiff-\(UUID().uuidString)")
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

        let dir1 = wc.appendingPathComponent("dir1")
        let dir2 = wc.appendingPathComponent("dir2")
        let medDir = wc.appendingPathComponent("med")
        try fm.createDirectory(at: dir1, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir2, withIntermediateDirectories: true)
        try fm.createDirectory(at: medDir, withIntermediateDirectories: true)

        let files = ["dir1/f1.txt", "dir1/f2.txt", "dir2/f3.txt", "dir2/f4.txt"]
        for rel in files {
            try "base line\n".write(to: wc.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        let medFiles = (1...6).map { "med/m\($0).txt" }
        for rel in medFiles {
            try "med base\n".write(to: wc.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try "small tail base\n".write(to: wc.appendingPathComponent("z_tail.txt"), atomically: true, encoding: .utf8)
        _ = try await client.add(workingCopy: wc, paths: ["dir1", "dir2", "med", "z_tail.txt"])
        _ = try await client.commit(workingCopy: wc, paths: [], message: "r1", progress: nil)

        let payload = (1...30).map { "line \($0) " + String(repeating: "B", count: 30) }.joined(separator: "\n") + "\n"
        for rel in files {
            try payload.write(to: wc.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        for rel in medFiles {
            try payload.write(to: wc.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try "small tail modified\n".write(to: wc.appendingPathComponent("z_tail.txt"), atomically: true, encoding: .utf8)

        // 1. Single oversized file followed by small file: oversized file is truncated, subsequent small file is intact
        let perFileCapDiffs = try await client.diff(
            workingCopy: wc,
            paths: ["dir1/f1.txt", "z_tail.txt"],
            maxBytes: 512,
            totalMaxBytes: 65536,
            maxSections: 100
        )
        expect(perFileCapDiffs.map(\.path) == ["dir1/f1.txt", "z_tail.txt"])
        expect(perFileCapDiffs[0].isTruncated)
        expect(!perFileCapDiffs[1].isTruncated)
        expect(perFileCapDiffs[1].addedCount == 1 && perFileCapDiffs[1].removedCount == 1)

        // 2. Many medium files in a single group: each < maxBytes (4096), but cumulative > totalMaxBytes (2500)
        let manyMedCapped = try await client.diff(
            workingCopy: wc,
            paths: ["med"],
            maxBytes: 4096,
            totalMaxBytes: 2500,
            maxSections: 100
        )
        expect(manyMedCapped.count < medFiles.count)
        expect(manyMedCapped.first?.isTruncated == false)
        expect(manyMedCapped.last?.isTruncated == true)

        // 3. Swapped parent/child target order must yield identical, deduplicated diffs
        let orderA = try await client.diff(workingCopy: wc, paths: ["dir1", "dir1/f1.txt"])
        let orderB = try await client.diff(workingCopy: wc, paths: ["dir1/f1.txt", "dir1"])
        expect(orderA.map(\.path) == orderB.map(\.path))
        expect(orderA.map(\.addedCount) == orderB.map(\.addedCount))

        let rootOrderA = try await client.diff(workingCopy: wc, paths: [".", "dir1/f1.txt", "z_tail.txt"])
        let rootOrderB = try await client.diff(workingCopy: wc, paths: ["z_tail.txt", "dir1/f1.txt", "."])
        expect(rootOrderA.map(\.path) == rootOrderB.map(\.path))
        expect(rootOrderA.map(\.addedCount) == rootOrderB.map(\.addedCount))

        // 4. maxSections cap: modified files with maxSections = 2 returns at most 2 files and marks truncation
        let sectionCapped = try await client.diff(
            workingCopy: wc,
            paths: [],
            maxBytes: 65536,
            totalMaxBytes: 65536,
            maxSections: 2
        )
        expect(sectionCapped.count == 2)
        expect(sectionCapped.last?.isTruncated == true)

        // 5. Cumulative totalMaxBytes across multiple diffGroups ("dir1" and "dir2")
        let groupCapped = try await client.diff(
            workingCopy: wc,
            paths: ["dir1", "dir2"],
            maxBytes: 65536,
            totalMaxBytes: 1200,
            maxSections: 100
        )
        expect(groupCapped.count < 4)
        expect(groupCapped.contains { $0.isTruncated })

        // 6. Unwritable directory (0500): diff must not depend on writable current directory or temp files
        do {
            let roDir = tempRoot.appendingPathComponent("readonly-dir")
            try fm.createDirectory(at: roDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)
            let prevCWD = fm.currentDirectoryPath
            _ = fm.changeCurrentDirectoryPath(roDir.path)
            defer {
                _ = fm.changeCurrentDirectoryPath(prevCWD)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roDir.path)
            }
            let roDiff = try await client.diff(workingCopy: wc, paths: ["z_tail.txt"])
            expect(roDiff.count == 1 && roDiff.first?.path == "z_tail.txt")
        }

        // 7. Revision diff (diffRevision) and historical copyfrom URL diff (csvn_diff_urls) with caps
        _ = try await client.update(workingCopy: wc, revision: nil, progress: nil)
        try runProcess(svn, ["copy", wc.appendingPathComponent("dir1/f1.txt").path, wc.appendingPathComponent("dir1/f1_copied.txt").path])
        let extraCopyLines = (1...25).map { "copied extra \($0) " + String(repeating: "C", count: 25) }.joined(separator: "\n") + "\n"
        try (payload + extraCopyLines).write(to: wc.appendingPathComponent("dir1/f1_copied.txt"), atomically: true, encoding: .utf8)
        _ = try await client.commit(workingCopy: wc, paths: [], message: "r2", progress: nil)

        let revDiffCapped = try await client.diffRevision(2, path: nil, maxBytes: 4096, totalMaxBytes: 1200, maxFiles: 2)
        expect(revDiffCapped.count <= 2)
        expect(revDiffCapped.contains { $0.isTruncated })

        let copyChange = ChangedPath(
            action: .added,
            path: "/dir1/f1_copied.txt",
            kind: .file,
            copyFromPath: "/dir1/f1.txt",
            copyFromRevision: 1
        )
        let copyUrlDiffCapped = try await client.diffFile(revision: 2, change: copyChange, maxBytes: 300)
        expect(copyUrlDiffCapped.isTruncated)
        expect(copyUrlDiffCapped.addedCount > 0)

        // 8. Deterministic C-level and Swift Task-level cancellation verification
        var errBuf = [CChar](repeating: 0, count: 256)
        if let cCtx = csvn_context_create(nil, nil, nil, nil, nil, nil, nil, nil, &errBuf, 256) {
            defer { csvn_context_destroy(cCtx) }

            var probeAddr = sockaddr_in()
            probeAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            probeAddr.sin_family = sa_family_t(AF_INET)
            probeAddr.sin_port = 0
            probeAddr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let probeSock = socket(AF_INET, SOCK_STREAM, 0)
            expect(probeSock >= 0)
            defer { close(probeSock) }
            let probeBindRC = withUnsafePointer(to: &probeAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(probeSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            expect(probeBindRC == 0)
            expect(listen(probeSock, 4) == 0)
            var probeLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &probeAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(probeSock, $0, &probeLen)
                }
            }
            let probePort = Int(UInt16(bigEndian: probeAddr.sin_port))
            let probeURLStr = "http://127.0.0.1:\(probePort)/repo/dir1/f1.txt"

            csvn_request_cancel(cCtx)
            var outText: UnsafeMutablePointer<CChar>? = nil
            var outLen: Int = 0
            var outTrunc: Int32 = 0
            var outSections: UnsafeMutablePointer<csvn_diff_section>? = nil
            var outSecCount: Int32 = 0
            var outTotalTrunc: Int32 = 0
            let fileURLStr = URL(fileURLWithPath: repo.path).appendingPathComponent("dir1/f1.txt").absoluteString

            let rcCancelDiffCapped = wc.path.withCString { p in
                csvn_diff_capped(cCtx, p, 4096, &outText, &outLen, &outTrunc)
            }
            expect(rcCancelDiffCapped == -7 && outText == nil && outLen == 0)

            let rcCancelDiffSections = wc.path.withCString { p in
                csvn_diff_sections_ex(cCtx, p, p, 4096, 65536, 16, &outSections, &outSecCount, &outTotalTrunc)
            }
            expect(rcCancelDiffSections == -7 && outSections == nil && outSecCount == 0)

            let rcCancelRev = probeURLStr.withCString { u in
                csvn_diff_revision(cCtx, u, 2, 4096, &outText, &outLen, &outTrunc)
            }
            expect(rcCancelRev == -7 && outText == nil && outLen == 0)

            let rcCancelUrls = probeURLStr.withCString { u in
                csvn_diff_urls(cCtx, u, 1, u, 2, 4096, &outText, &outLen, &outTrunc)
            }
            expect(rcCancelUrls == -7 && outText == nil && outLen == 0)

            let rcCancelCat = probeURLStr.withCString { u in
                csvn_cat_capped(cCtx, u, 2, 4096, &outText, &outLen, &outTrunc)
            }
            expect(rcCancelCat == -7 && outText == nil && outLen == 0)

            var outRev: Int32 = 0
            var outUpd: Int32 = 0
            var outAdd: Int32 = 0
            var outDel: Int32 = 0
            var outConf: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(bitPattern: 0x1)
            var outConfCnt: Int32 = 99
            var outComm: Int32 = 0
            let rcCancelCheckout = probeURLStr.withCString { u in
                wc.path.withCString { d in
                    csvn_checkout(cCtx, u, d, 0, &outRev)
                }
            }
            expect(rcCancelCheckout == -7)

            let rcCancelUpdate = wc.path.withCString { p in
                csvn_update(cCtx, p, 0, &outRev, &outUpd, &outAdd, &outDel, &outConf, &outConfCnt)
            }
            expect(rcCancelUpdate == -7 && outConf == nil && outConfCnt == 0)

            var wcTargetPtr: UnsafePointer<CChar>? = UnsafePointer(strdup(wc.path))
            defer { if let wcTargetPtr { free(UnsafeMutablePointer(mutating: wcTargetPtr)) } }
            let rcCancelCommit = "cancelled".withCString { m in
                csvn_commit(cCtx, &wcTargetPtr, 1, m, 0, &outRev, &outComm)
            }
            expect(rcCancelCommit == -7)
            expect(csvn_revert(cCtx, &wcTargetPtr, 1, 0) == -7)
            expect(csvn_add(cCtx, &wcTargetPtr, 1) == -7)
            let rcCancelValidate = wc.path.withCString { r in
                csvn_validate_write_targets(cCtx, r, &wcTargetPtr, 1, 0, 0)
            }
            expect(rcCancelValidate == -7)
            var relTargetPtr: UnsafePointer<CChar>? = UnsafePointer(strdup("z_tail.txt"))
            defer { if let relTargetPtr { free(UnsafeMutablePointer(mutating: relTargetPtr)) } }
            let rcCancelDelete = wc.path.withCString { r in
                csvn_delete_files(cCtx, r, &relTargetPtr, 1)
            }
            expect(rcCancelDelete == -7)
            let rcCancelMove = wc.path.withCString { r in
                "z_tail.txt".withCString { s in
                    "z_moved.txt".withCString { d in
                        csvn_move_file(cCtx, r, s, d)
                    }
                }
            }
            expect(rcCancelMove == -7)
            let rcCancelCopy = wc.path.withCString { r in
                "z_tail.txt".withCString { s in
                    "z_copied.txt".withCString { d in
                        csvn_copy_file(cCtx, r, s, d)
                    }
                }
            }
            expect(rcCancelCopy == -7)
            let rcCancelResolve = wc.path.withCString { r in
                "z_tail.txt".withCString { p in
                    csvn_resolve_text(cCtx, r, p, 0)
                }
            }
            expect(rcCancelResolve == -7)
            var mergeRes = csvn_merge_result()
            let rcCancelMerge = wc.path.withCString { r in
                probeURLStr.withCString { u in
                    csvn_merge_range(cCtx, r, u, 1, 2, 2, 1, &mergeRes)
                }
            }
            expect(rcCancelMerge == -7 && mergeRes.started == 0)

            var pfd = pollfd(fd: probeSock, events: Int16(POLLIN), revents: 0)
            expect(poll(&pfd, 1, 0) == 0)

            csvn_clear_cancel(cCtx)
            let rcAfterClear = fileURLStr.withCString { u in
                csvn_diff_revision(cCtx, u, 2, 4096, &outText, &outLen, &outTrunc)
            }
            expect(rcAfterClear == 0 && outText != nil && outLen > 0)
            if let outText {
                csvn_free_string(outText)
            }
        } else {
            expect(false)
        }

        // Swift Task cancellation:
        // (a) Pre-cancelled Task must deterministically throw CancellationError
        var threwCancellation = false
        let cancelTask = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await client.diff(workingCopy: wc, paths: [])
        }
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
        } catch is CancellationError {
            threwCancellation = true
        }
        expect(threwCancellation)

        // (b) Runtime in-flight cancellation & queued operation isolation against a delayed loopback HTTP server
        let cancelStateDir = tempRoot.appendingPathComponent("cancel-http")
        try fm.createDirectory(at: cancelStateDir, withIntermediateDirectories: true)
        let cancelPortFile = cancelStateDir.appendingPathComponent("port.txt")
        let cancelServerScript = cancelStateDir.appendingPathComponent("server.py")
        try """
        import http.server, pathlib, sys, time

        state_dir, port_path = sys.argv[1:3]
        root = pathlib.Path(state_dir)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def do_OPTIONS(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length:
                    self.rfile.read(length)
                tag = self.path.strip("/") or "default"
                arrived = root / f"{tag}.arrived"
                release = root / f"{tag}.release"
                arrived.write_text("1")
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline and not release.exists():
                    time.sleep(0.01)
                mode = release.read_text().strip() if release.exists() else "403"
                if mode == "200":
                    body = (
                        b'<?xml version="1.0" encoding="utf-8"?>'
                        b'<D:options-response xmlns:D="DAV:">'
                        b'<D:activity-collection-set><D:href>/' + tag.encode() + b'/!svn/act/</D:href></D:activity-collection-set>'
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
                    self.send_header("SVN-Youngest-Rev", "7")
                    self.send_header("SVN-Repository-UUID", "22222222-3333-4444-5555-666666666666")
                    self.send_header("SVN-Repository-Root", f"/{tag}")
                    self.send_header("SVN-Me-Resource", f"/{tag}/!svn/me")
                    self.send_header("SVN-Rev-Root-Stub", f"/{tag}/!svn/rvr")
                    self.send_header("SVN-Rev-Stub", f"/{tag}/!svn/rev")
                    self.send_header("SVN-Txn-Root-Stub", f"/{tag}/!svn/txr")
                    self.send_header("SVN-Txn-Stub", f"/{tag}/!svn/txn")
                    self.send_header("SVN-VTxn-Root-Stub", f"/{tag}/!svn/vtxr")
                    self.send_header("SVN-VTxn-Stub", f"/{tag}/!svn/vtxn")
                    self.send_header("Content-Type", 'text/xml; charset="utf-8"')
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        pathlib.Path(port_path).write_text(str(srv.server_port))
        srv.serve_forever()
        """.write(to: cancelServerScript, atomically: true, encoding: .utf8)

        let cancelErrFile = cancelStateDir.appendingPathComponent("cancel-server.err")
        let cancelServerPID = try spawnBackgroundProcess("/usr/bin/python3", [
            cancelServerScript.path, cancelStateDir.path, cancelPortFile.path
        ], stderrPath: cancelErrFile.path)
        defer {
            stopBackgroundProcess(cancelServerPID)
        }

        let cancelPort = try await waitForBackgroundPort(
            cancelServerPID,
            portFile: cancelPortFile,
            stderrFile: cancelErrFile,
            label: "cancel-http-server"
        )
        try "small tail modified after r2\n".write(to: wc.appendingPathComponent("z_tail.txt"), atomically: true, encoding: .utf8)

        // Case 1: Run A (in-flight HTTP OPTIONS), queue B on same client, cancel ONLY B -> B throws CancellationError, A is unaffected
        let case1URL = require(URL(string: "http://127.0.0.1:\(cancelPort)/case1"))
        let case1Arrived = cancelStateDir.appendingPathComponent("case1.arrived")
        let case1Release = cancelStateDir.appendingPathComponent("case1.release")
        let taskA1 = Task {
            try await client.connect(to: case1URL, credentials: nil)
        }
        var a1InFlight = false
        for _ in 0..<50 {
            if fm.fileExists(atPath: case1Arrived.path) {
                a1InFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(a1InFlight)

        let taskB1 = Task {
            try await client.diff(workingCopy: wc, paths: ["z_tail.txt"])
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        taskB1.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        try "200".write(to: case1Release, atomically: true, encoding: .utf8)

        var b1Cancelled = false
        do {
            _ = try await taskB1.value
        } catch is CancellationError {
            b1Cancelled = true
        }
        expect(b1Cancelled)

        let a1Info = try await taskA1.value
        expect(a1Info.youngestRevision == 7)

        // Case 2: Run A (in-flight HTTP OPTIONS blocked for up to 5s), queue B on same client, cancel ONLY running A
        // WITHOUT releasing the server -> A must be interrupted in C via csvn_cancel_check and throw CancellationError
        // in < 2.0s (well before the 5s server deadline), while B succeeds and client state rolls back to case1URL
        let case2URL = require(URL(string: "http://127.0.0.1:\(cancelPort)/case2"))
        let case2Arrived = cancelStateDir.appendingPathComponent("case2.arrived")
        let case2Release = cancelStateDir.appendingPathComponent("case2.release")
        let taskA2 = Task {
            try await client.connect(to: case2URL, credentials: nil)
        }
        var a2InFlight = false
        for _ in 0..<50 {
            if fm.fileExists(atPath: case2Arrived.path) {
                a2InFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(a2InFlight)

        let taskB2 = Task {
            try await client.diff(workingCopy: wc, paths: ["z_tail.txt"])
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let a2CancelStart = ContinuousClock.now
        taskA2.cancel()

        let a2Cancelled: Bool = await {
            do {
                _ = try await taskA2.value
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }()
        let a2CancelElapsed = ContinuousClock.now - a2CancelStart
        expect(a2Cancelled)
        expect(a2CancelElapsed < .seconds(2))
        expect(!fm.fileExists(atPath: case2Release.path))
        expect(client.repositoryRoot == case1URL)

        let b2Diffs = try await taskB2.value
        expect(b2Diffs.count == 1 && b2Diffs.first?.path == "z_tail.txt")
        try "403".write(to: case2Release, atomically: true, encoding: .utf8)

        // Case 3: Multiple queued operations (B, C, D) behind in-flight A; cancel D and B in reverse order while C and subsequent E succeed
        let case3URL = require(URL(string: "http://127.0.0.1:\(cancelPort)/case3"))
        let case3Arrived = cancelStateDir.appendingPathComponent("case3.arrived")
        let case3Release = cancelStateDir.appendingPathComponent("case3.release")
        let taskA3 = Task {
            try await client.connect(to: case3URL, credentials: nil)
        }
        var a3InFlight = false
        for _ in 0..<50 {
            if fm.fileExists(atPath: case3Arrived.path) {
                a3InFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(a3InFlight)

        let taskB3 = Task { try await client.diff(workingCopy: wc, paths: ["dir1", "dir2"]) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let taskC3 = Task { try await client.diff(workingCopy: wc, paths: ["z_tail.txt"]) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let taskD3 = Task { try await client.status(of: wc) }
        try await Task.sleep(nanoseconds: 20_000_000)

        taskD3.cancel()
        taskB3.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        try "200".write(to: case3Release, atomically: true, encoding: .utf8)

        var b3Cancelled = false
        do { _ = try await taskB3.value } catch is CancellationError { b3Cancelled = true }
        expect(b3Cancelled)

        var d3Cancelled = false
        do { _ = try await taskD3.value } catch is CancellationError { d3Cancelled = true }
        expect(d3Cancelled)

        let a3Info = try await taskA3.value
        expect(a3Info.youngestRevision == 7)
        let c3Diffs = try await taskC3.value
        expect(c3Diffs.count == 1 && c3Diffs.first?.path == "z_tail.txt")
        let e3Status = try await client.status(of: wc)
        expect(e3Status.contains { $0.path == "z_tail.txt" })

        // Case 4: Cross-instance performWrite cancelled while waiting on workingCopyWriteLock must return CancellationError
        // promptly (< 0.5s) while W1 still holds the lock, unblock subsequent reads on W2, and not mutate working copy
        let case4URL = require(URL(string: "http://127.0.0.1:\(cancelPort)/case4"))
        let case4Arrived = cancelStateDir.appendingPathComponent("case4.arrived")
        let case4Release = cancelStateDir.appendingPathComponent("case4.release")
        let writer1 = try SVNClient(baseURL: case4URL, useSavedCredentials: false)
        let writer2 = try SVNClient(useSavedCredentials: false)
        let dummyDest = tempRoot.appendingPathComponent("wc-checkout-lock")
        let taskW1 = Task {
            try await writer1.checkout(path: nil, to: dummyDest, revision: nil)
        }
        var w1InFlight = false
        for _ in 0..<50 {
            if fm.fileExists(atPath: case4Arrived.path) {
                w1InFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(w1InFlight)

        let taskW2 = Task {
            try await writer2.setProperty("user:cancelled-prop", value: Data("should-not-write".utf8), workingCopy: wc, path: "z_tail.txt")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let taskR2 = Task {
            try await writer2.status(of: wc)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let w2CancelStart = ContinuousClock.now
        taskW2.cancel()
        var w2Cancelled = false
        do {
            try await taskW2.value
        } catch is CancellationError {
            w2Cancelled = true
        }
        let w2CancelElapsed = ContinuousClock.now - w2CancelStart
        expect(w2Cancelled)
        expect(w2CancelElapsed < .milliseconds(500))
        expect(!fm.fileExists(atPath: case4Release.path))

        let r2Statuses = try await taskR2.value
        expect(r2Statuses.contains { $0.path == "z_tail.txt" })
        expect(!fm.fileExists(atPath: case4Release.path))

        // Now queue W3 on writer2 (waiting on workingCopyWriteLock held by W1) and cancel the lock-holding W1
        // via writer1.requestCancel() WITHOUT releasing the server -> W1 must abort in C (< 2.0s) and release
        // workingCopyWriteLock so W3 acquires the lock and succeeds while case4.release still does not exist
        let taskW3 = Task {
            try await writer2.setProperty("user:after-w1-cancel", value: Data("ok".utf8), workingCopy: wc, path: "z_tail.txt")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let w1CancelStart = ContinuousClock.now
        writer1.requestCancel()

        var w1Cancelled = false
        do {
            _ = try await taskW1.value
        } catch is CancellationError {
            w1Cancelled = true
        }
        try await taskW3.value
        let w1AndW3Elapsed = ContinuousClock.now - w1CancelStart
        expect(w1Cancelled)
        expect(w1AndW3Elapsed < .seconds(2))
        expect(!fm.fileExists(atPath: case4Release.path))
        try "403".write(to: case4Release, atomically: true, encoding: .utf8)

        let propAfterCancel = try await client.property("user:cancelled-prop", at: .workingCopy(root: wc, path: "z_tail.txt"))
        expect(propAfterCancel == nil)
        let propAfterW3 = try await client.property("user:after-w1-cancel", at: .workingCopy(root: wc, path: "z_tail.txt"))
        expect(propAfterW3 == Data("ok".utf8))
        try await writer2.setProperty("user:after-w1-cancel", value: nil, workingCopy: wc, path: "z_tail.txt")

        // Case 5: disconnect() called from an already-cancelled Task must still clean up handle and rootURL
        let disconnectTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await writer1.disconnect()
        }
        await disconnectTask.value
        expect(writer1.repositoryRoot == nil)
        var disconnectedBrowseFailed = false
        do {
            _ = try await writer1.browse(path: nil)
        } catch {
            disconnectedBrowseFailed = true
        }
        expect(disconnectedBrowseFailed)

        // Restore connection to local file:// repository for subsequent checks
        _ = try await client.connect(to: URL(fileURLWithPath: repo.path), credentials: nil)

        // Also exercise direct client.requestCancel() followed by a fresh uncancelled call
        client.requestCancel()
        let afterCancel = try await client.diffRevision(2, path: nil, maxBytes: 4096)
        expect(!afterCancel.isEmpty)

        // 9. Verify no /tmp/csvn-*diff* or /tmp/csvn-err-* temporary files were leaked
        let tmpEntries = (try? fm.contentsOfDirectory(atPath: "/tmp")) ?? []
        let leaked = tmpEntries.filter {
            $0.hasPrefix("csvn-diff-") || $0.hasPrefix("csvn-rdiff-") || $0.hasPrefix("csvn-udiff-") || $0.hasPrefix("csvn-err-")
        }
        expect(leaked.isEmpty)
    }
}
