import XCTest
@testable import CVCSKit
@testable import CSVNKit

final class CVCSKitTests: XCTestCase {

    func testParseSingleFileUnifiedDiff() {
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
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 2)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].newCount, 3)
        XCTAssertEqual(hunks[0].lines.count, 4)
        XCTAssertEqual(hunks[0].lines[0].kind, .context)
        XCTAssertEqual(hunks[0].lines[1].kind, .deletion)
        XCTAssertEqual(hunks[0].lines[2].kind, .addition)
        XCTAssertEqual(hunks[0].lines[3].kind, .addition)
    }

    func testParseMultiFileDiffDoesNotBleedHeadersIntoPreviousHunk() {
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
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs[0].path, "src/a.txt")
        XCTAssertEqual(diffs[0].addedCount, 1)
        XCTAssertEqual(diffs[0].removedCount, 1)
        XCTAssertEqual(diffs[1].path, "docs/b.txt")
        XCTAssertEqual(diffs[1].addedCount, 1)
        XCTAssertEqual(diffs[1].removedCount, 0)
    }

    func testWorkingCopyStatusPendingFlag() {
        XCTAssertTrue(WorkingCopyStatus.Kind.modified.isPendingChange)
        XCTAssertTrue(WorkingCopyStatus.Kind.added.isPendingChange)
        XCTAssertTrue(WorkingCopyStatus.Kind.deleted.isPendingChange)
        XCTAssertFalse(WorkingCopyStatus.Kind.normal.isPendingChange)
        XCTAssertFalse(WorkingCopyStatus.Kind.unversioned.isPendingChange)
    }
}
