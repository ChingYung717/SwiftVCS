import Foundation
import CVCSKit
import CSVNKit

@main
struct CVCSKitTests {
    static func main() {
        testParseSingleFileUnifiedDiff()
        testParseMultiFileDiffDoesNotBleedHeadersIntoPreviousHunk()
        testWorkingCopyStatusPendingFlag()
        testKeychainScopeIncludesProtocolPortAndRepository()
        testMergeRevisionRange()
        testCompleteAndTruncatedText()
        print("6 unit tests passed")
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
}
