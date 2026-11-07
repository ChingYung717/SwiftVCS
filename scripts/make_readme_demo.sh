#!/bin/bash
# 生成 README 截图与离线体验所用的本地 SVN 演示仓库（完全离线，file:// 协议）。
# 用法: ./scripts/make_readme_demo.sh [输出目录]
set -euo pipefail

if command -v brew >/dev/null 2>&1 && [ -d "$(brew --prefix subversion 2>/dev/null)/bin" ]; then
    SVN_BIN="$(brew --prefix subversion 2>/dev/null)/bin"
elif [ -d "/opt/homebrew/opt/subversion/bin" ]; then
    SVN_BIN="/opt/homebrew/opt/subversion/bin"
elif [ -d "/usr/local/opt/subversion/bin" ]; then
    SVN_BIN="/usr/local/opt/subversion/bin"
elif command -v svnadmin >/dev/null 2>&1; then
    SVN_BIN="$(dirname "$(command -v svnadmin)")"
else
    echo "错误：未找到 svn / svnadmin，请先执行 brew install subversion" >&2
    exit 1
fi

BASE="${1:-/tmp/swiftvcs-demo}"
if [ -z "$BASE" ] || [ -L "$BASE" ]; then
    echo "错误：输出目录不能为空或符号链接" >&2
    exit 1
fi
mkdir -p "$BASE"
BASE="$(cd "$BASE" && pwd -P)"
if [ "$BASE" = "/" ] || [ "$BASE" = "${HOME:-}" ]; then
    echo "错误：不能将根目录或用户主目录直接作为演示输出目录" >&2
    exit 1
fi

REPO_DIR="$BASE/SwiftVCSDemo"
WC_DIR="$BASE/SwiftVCSDemo-wc"
if [ -L "$REPO_DIR" ] || [ -L "$WC_DIR" ]; then
    echo "错误：演示子目录不能为符号链接" >&2
    exit 1
fi
rm -rf "$REPO_DIR" "$WC_DIR"
REPO_URL="file://$REPO_DIR"

"$SVN_BIN/svnadmin" create "$REPO_DIR"
# 允许修改 svn:date 等修订属性，便于生成固定、可读性好的演示时间线
cat > "$REPO_DIR/hooks/pre-revprop-change" <<'HOOK'
#!/bin/sh
exit 0
HOOK
chmod +x "$REPO_DIR/hooks/pre-revprop-change"

"$SVN_BIN/svn" checkout -q "$REPO_URL" "$WC_DIR"
cd "$WC_DIR"

# r1: 初始化工程结构 (alice)
mkdir -p Sources/SyncEngine Tests Docs
cat > Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftVCSDemo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    targets: [
        .target(
            name: "SyncEngine",
            path: "Sources/SyncEngine"
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine"],
            path: "Tests"
        ),
    ]
)
EOF

cat > README.md <<'EOF'
# SwiftVCSDemo — 增量同步引擎示例

用于演示 **SwiftVCS / VCS Explorer** 的历史记录、并排/统一代码比对、工作副本变更与远端目录浏览。

## 模块说明
- `Sources/SyncEngine/AdaptiveScheduler.swift`：自适应并发同步调度器
- `Sources/SyncEngine/ChecksumVerifier.swift`：SHA-256 块校验器
- `Sources/SyncEngine/MetadataCache.swift`：本地修订元数据缓存
- `Sources/SyncEngine/RetryPolicy.swift`：指数退避重试策略
EOF

cat > Sources/SyncEngine/AdaptiveScheduler.swift <<'EOF'
import Foundation

/// 负责调度远端快照拉取与增量差异计算任务。
public struct SchedulerConfiguration: Sendable {
    public var maxConcurrentTasks: Int
    public var requestTimeoutSeconds: TimeInterval
    public var enableBatchCompression: Bool

    public init(
        maxConcurrentTasks: Int = 2,
        requestTimeoutSeconds: TimeInterval = 15.0,
        enableBatchCompression: Bool = false
    ) {
        self.maxConcurrentTasks = maxConcurrentTasks
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.enableBatchCompression = enableBatchCompression
    }
}

public actor AdaptiveScheduler {
    private var config: SchedulerConfiguration
    private var completedRevisions: Int = 0

    public init(configuration: SchedulerConfiguration = .init()) {
        self.config = configuration
    }

    public func scheduleBatch(revisions: [Int]) async throws -> Int {
        guard !revisions.isEmpty else { return 0 }
        completedRevisions += revisions.count
        return revisions.count
    }

    public func currentConcurrencyLimit() -> Int {
        config.maxConcurrentTasks
    }
}
EOF

cat > Sources/SyncEngine/ChecksumVerifier.swift <<'EOF'
import Foundation

public struct ChecksumVerifier: Sendable {
    public init() {}

    public func verify(payload: Data, expectedHex: String) -> Bool {
        let normalized = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !payload.isEmpty, normalized.count == 64 else { return false }
        return true
    }
}
EOF

cat > Docs/Architecture.md <<'EOF'
# 同步引擎架构设计

1. **连接层**：管理会话、凭据与 TLS 叶证书指纹校验。
2. **调度层 (`AdaptiveScheduler`)**：控制并发窗口与批处理队列。
3. **缓存层 (`MetadataCache`)**：按修订号缓存节点属性与变更摘要。
EOF

"$SVN_BIN/svn" add -q Package.swift README.md Sources Tests Docs
"$SVN_BIN/svn" commit -q --username alice -m "chore: 初始化 SwiftVCSDemo 示例工程与核心模块"

# r2: 新增重试策略 (bob)
cat > Sources/SyncEngine/RetryPolicy.swift <<'EOF'
import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelayMilliseconds: Int

    public init(maxAttempts: Int = 3, baseDelayMilliseconds: Int = 200) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayMilliseconds = max(50, baseDelayMilliseconds)
    }

    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let shift = min(max(0, attempt - 1), 5)
        let ms = baseDelayMilliseconds * (1 << shift)
        return UInt64(ms) * 1_000_000
    }
}
EOF

"$SVN_BIN/svn" add -q Sources/SyncEngine/RetryPolicy.swift
"$SVN_BIN/svn" commit -q --username bob -m "feat(retry): 新增指数退避重试策略 RetryPolicy"

# r3: 新增元数据缓存与中文注释支持 (carol)
cat > Sources/SyncEngine/MetadataCache.swift <<'EOF'
import Foundation

/// 缓存已拉取的修订元数据，避免重复查询远端仓库。
public actor MetadataCache {
    public struct Entry: Sendable {
        public let revision: Int
        public let author: String
        public let summary: String
    }

    private var storage: [Int: Entry] = [:]
    private let capacity: Int

    public init(capacity: Int = 128) {
        self.capacity = max(16, capacity)
    }

    public func store(_ entry: Entry) {
        storage[entry.revision] = entry
    }

    public func entry(forRevision revision: Int) -> Entry? {
        storage[revision]
    }
}
EOF

"$SVN_BIN/svn" add -q Sources/SyncEngine/MetadataCache.swift
"$SVN_BIN/svn" commit -q --username carol -m "feat(cache): 新增修订元数据 LRU 缓存参与者 MetadataCache"

# r4: 复制并演进校验器 (A+ copyfrom) + 设置 SVN 属性 (bob)
"$SVN_BIN/svn" copy -q Sources/SyncEngine/ChecksumVerifier.swift Sources/SyncEngine/SnapshotValidator.swift
cat > Sources/SyncEngine/SnapshotValidator.swift <<'EOF'
import Foundation

/// 基于 ChecksumVerifier 演进的快照完整性校验器（演示 SVN copyfrom 跨路径比对）。
public struct SnapshotValidator: Sendable {
    public let strictMode: Bool

    public init(strictMode: Bool = true) {
        self.strictMode = strictMode
    }

    public func verifySnapshot(payload: Data, expectedHex: String) -> Bool {
        let normalized = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !payload.isEmpty, normalized.count == 64 else { return false }
        return strictMode ? payload.count >= 4 : true
    }
}
EOF
"$SVN_BIN/svn" propset -q svn:eol-style native Sources/SyncEngine/SnapshotValidator.swift
"$SVN_BIN/svn" commit -q --username bob -m "refactor(validator): 从 ChecksumVerifier 派生 SnapshotValidator 并开启严格校验"

# r5: 补充架构文档与缓存淘汰逻辑 (carol)
cat >> Docs/Architecture.md <<'EOF'
4. **校验层 (`SnapshotValidator`)**：对快照分块与属性清单做完整性校验。
EOF
"$SVN_BIN/svn" commit -q --username carol -m "docs(arch): 补充快照完整性校验层说明"

# r6: 最新提交 (alice) —— 包含多文件变更 (M + A) 与清晰的增删对比块，打开即自动选中展示
cat > Sources/SyncEngine/AdaptiveScheduler.swift <<'EOF'
import Foundation

/// 负责调度远端快照拉取与增量差异计算任务。
public struct SchedulerConfiguration: Sendable {
    public var maxConcurrentTasks: Int
    public var minConcurrentTasks: Int
    public var requestTimeoutSeconds: TimeInterval
    public var enableBatchCompression: Bool
    public var retryPolicy: RetryPolicy

    public init(
        maxConcurrentTasks: Int = 6,
        minConcurrentTasks: Int = 2,
        requestTimeoutSeconds: TimeInterval = 30.0,
        enableBatchCompression: Bool = true,
        retryPolicy: RetryPolicy = .init()
    ) {
        self.maxConcurrentTasks = max(minConcurrentTasks, maxConcurrentTasks)
        self.minConcurrentTasks = max(1, minConcurrentTasks)
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.enableBatchCompression = enableBatchCompression
        self.retryPolicy = retryPolicy
    }
}

public actor AdaptiveScheduler {
    private var config: SchedulerConfiguration
    private var completedRevisions: Int = 0
    private var recentLatencyMs: [Double] = []

    public init(configuration: SchedulerConfiguration = .init()) {
        self.config = configuration
    }

    public func scheduleBatch(revisions: [Int], onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        guard !revisions.isEmpty else { return 0 }
        try Task.checkCancellation()
        for (index, _) in revisions.enumerated() {
            onProgress?(index + 1)
        }
        completedRevisions += revisions.count
        return revisions.count
    }

    public func adjustedConcurrencyLimit(lastRoundtripMs: Double) -> Int {
        recentLatencyMs.append(lastRoundtripMs)
        if lastRoundtripMs > 450 {
            return max(config.minConcurrentTasks, config.maxConcurrentTasks / 2)
        }
        return config.maxConcurrentTasks
    }
}
EOF

cat > Sources/SyncEngine/RetryPolicy.swift <<'EOF'
import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelayMilliseconds: Int
    public let maxDelayMilliseconds: Int

    public init(
        maxAttempts: Int = 4,
        baseDelayMilliseconds: Int = 200,
        maxDelayMilliseconds: Int = 3_200
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayMilliseconds = max(50, baseDelayMilliseconds)
        self.maxDelayMilliseconds = max(self.baseDelayMilliseconds, maxDelayMilliseconds)
    }

    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let shift = min(max(0, attempt - 1), 5)
        let rawMs = baseDelayMilliseconds * (1 << shift)
        let boundedMs = min(rawMs, maxDelayMilliseconds)
        return UInt64(boundedMs) * 1_000_000
    }
}
EOF

cat > Tests/AdaptiveSchedulerTests.swift <<'EOF'
import XCTest
@testable import SyncEngine

final class AdaptiveSchedulerTests: XCTestCase {
    func testAdaptiveWindowShrinksOnHighLatency() async throws {
        let scheduler = AdaptiveScheduler()
        let limit = await scheduler.adjustedConcurrencyLimit(lastRoundtripMs: 620)
        XCTAssertGreaterThanOrEqual(limit, 2)
    }
}
EOF

"$SVN_BIN/svn" add -q Tests/AdaptiveSchedulerTests.swift
"$SVN_BIN/svn" propset -q swiftvcs:component "retry-policy" Sources/SyncEngine/RetryPolicy.swift
"$SVN_BIN/svn" commit -q --username alice -m $'feat(scheduler): 引入自适应并发窗口、超时保护与退避上限\n\n- 根据最近往返耗时动态收缩并发上限，避免慢速链路拥塞\n- 为 scheduleBatch 增加结构化取消检查与进度回调\n- 为 RetryPolicy 增加最大退避时长上限与单元测试'

"$SVN_BIN/svn" update -q

# 在工作副本制造未提交改动，用于「更改 (Changes)」页签展示：
# 1. 修改 Sources/SyncEngine/AdaptiveScheduler.swift (M，排在第一位自动选中展示差异)
cat > Sources/SyncEngine/AdaptiveScheduler.swift <<'EOF'
import Foundation

/// 负责调度远端快照拉取与增量差异计算任务。
public struct SchedulerConfiguration: Sendable {
    public var maxConcurrentTasks: Int
    public var minConcurrentTasks: Int
    public var requestTimeoutSeconds: TimeInterval
    public var enableBatchCompression: Bool
    public var retryPolicy: RetryPolicy

    public init(
        maxConcurrentTasks: Int = 8,
        minConcurrentTasks: Int = 2,
        requestTimeoutSeconds: TimeInterval = 25.0,
        enableBatchCompression: Bool = true,
        retryPolicy: RetryPolicy = .init()
    ) {
        self.maxConcurrentTasks = max(minConcurrentTasks, maxConcurrentTasks)
        self.minConcurrentTasks = max(1, minConcurrentTasks)
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.enableBatchCompression = enableBatchCompression
        self.retryPolicy = retryPolicy
    }
}

public actor AdaptiveScheduler {
    private var config: SchedulerConfiguration
    private var completedRevisions: Int = 0
    private var recentLatencyMs: [Double] = []

    public init(configuration: SchedulerConfiguration = .init()) {
        self.config = configuration
    }

    public func scheduleBatch(revisions: [Int], onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        guard !revisions.isEmpty else { return 0 }
        try Task.checkCancellation()
        for (index, _) in revisions.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1)
        }
        completedRevisions += revisions.count
        return revisions.count
    }

    public func adjustedConcurrencyLimit(lastRoundtripMs: Double) -> Int {
        recentLatencyMs.append(lastRoundtripMs)
        if recentLatencyMs.count > 16 {
            recentLatencyMs.removeFirst()
        }
        if lastRoundtripMs > 400 {
            return max(config.minConcurrentTasks, config.maxConcurrentTasks / 2)
        }
        return config.maxConcurrentTasks
    }
}
EOF

# 2. 修改 Sources/SyncEngine/MetadataCache.swift (M)
cat >> Sources/SyncEngine/MetadataCache.swift <<'EOF'

    public func removeAll() {
        storage.removeAll(keepingCapacity: false)
    }
EOF

# 3. 新增已纳入版本控制的文件 Sources/SyncEngine/SyncMetrics.swift (A)
cat > Sources/SyncEngine/SyncMetrics.swift <<'EOF'
import Foundation

public struct SyncMetrics: Sendable {
    public let fetchedRevisions: Int
    public let elapsedMilliseconds: Double
}
EOF
"$SVN_BIN/svn" add -q Sources/SyncEngine/SyncMetrics.swift

# 4. 新增未纳管文件 Tests/SyncMetricsTests.swift (?，展示一键「+ 纳管」按钮)
cat > Tests/SyncMetricsTests.swift <<'EOF'
import XCTest
@testable import SyncEngine

final class SyncMetricsTests: XCTestCase {
    func testMetricsInit() {
        let m = SyncMetrics(fetchedRevisions: 12, elapsedMilliseconds: 84.5)
        XCTAssertEqual(m.fetchedRevisions, 12)
    }
}
EOF

echo "REPO_URL=$REPO_URL"
echo "WORKING_COPY=$WC_DIR"
