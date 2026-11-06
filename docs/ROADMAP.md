# SwiftVCS 功能路线图

## 基线与目标

以本地提交 `510b720` 为实现基线。当前 CLI 有 12 个命令，工作副本支持检出、更新、状态、纳管、差异、提交和放弃更改。测试基线为 4 项单元检查、45 项离线端到端断言和回环安全套件。CI 配置使用 `macos-15`，远端运行结果待核验。

P0 交付三个可独立验收的闭环，按 **工作副本文件操作 → 冲突处理 → 指定修订合并** 实施。每个闭环同步交付 libsvn 封装、Swift 接口、CLI、GUI、测试与用户文档。

| 能力 | P0 交付 | libsvn 入口 |
|---|---|---|
| 文件操作 | 工作副本内删除、重命名、移动、保留历史复制。先变更本地工作副本，用户随后提交 | `svn_client_delete4`、`svn_client_move7`、`svn_client_copy7` |
| 冲突处理 | 展示更新或合并产生的文本、属性、树冲突。为纯文本冲突提供四种处理方式 | `svn_client_conflict_get`、`svn_client_conflict_get_conflicted`、`svn_client_conflict_text_resolve_by_id` |
| 合并 | 将同仓库源分支的一个修订或一段正向修订合并到当前工作副本根。先预演，再应用，最后显式提交 | `svn_client_merge_peg5` |

仓库 URL 直接删除、移动、复制或建分支，目录级文件操作、拖拽、树或属性冲突的自动解决、三方编辑器、反向及自动合并列为后续。P0 继续通过 C shim 使用 libsvn。开发测试可使用 `svnadmin`、`svn`、`svnlook` 建夹具和比对结果。所有写入验收使用本地临时仓库和专用工作副本。

## P0.1 工作副本文件操作

- 首期支持已纳管文件，目标父目录须存在且已纳管。删除用 `force=false`、`keep_local=false`，对本地有修改或不可安全删除的对象报错。删除确认说明文件会立即从本地移除、仓库将在提交后变更。移动和复制拒绝覆盖、自动建目录和跨工作副本。复制使用工作副本源，保留 libsvn 记录的来源历史。
- `rename` 复用 `move`，目标限定为同目录的新文件名。跨目录目标用工作副本相对路径。大小写改名、Unicode 文件名和符号链接均有专门用例。未通过安全验收的路径形式应明确拒绝。
- 在变更前把路径限定到真实工作副本根。拒绝空路径、绝对路径、URL、`..`、`.svn`、跨外部工作副本和经符号链接逃逸的目标。使用 libsvn 核对工作副本归属，目标尚不存在时核对其父目录。现有 `localPath` 可接受绝对路径，不能直接用作新增写操作的校验。
- 从 `svn_client_status_t.moved_from_abspath` / `moved_to_abspath` 暴露移动关系。源显示删除，目标显示带历史的新增。提交或放弃移动时，对两端成对处理，界面在执行前展示实际作用范围。保留当前选择式提交行为，并验证目录递归提交不会把未勾选改动意外带入。
- Changes 默认筛选隐藏正常文件。提供可到达正常已纳管文件的操作入口，复用「显示全部」及行菜单，或提供工作副本文件选择。提交、移动和删除失败时刷新磁盘状态；若写入已完成但刷新失败，分别提示，避免用户误以为需要重试写入。

[Apache Subversion 客户端 API](https://subversion.apache.org/docs/api/latest/svn__client_8h.html)

## P0.2 冲突处理

- 更新后展示 `UpdateResult.conflicts`，并与刷新后的工作副本状态对照。Changes 显示冲突路径和类型，支持转到文件详情；未解决的选中项在提交前给出明确提示。区分「操作执行失败」和「操作完成但留有冲突」。
- P0 的四种快捷策略仅针对纯文本冲突，且只处理所选路径。根据 libsvn 返回的可用选项启用按钮。覆盖型策略确认后才执行；手工编辑通过现有文件打开流程完成，再由用户选择「采用当前文件」。属性冲突、树冲突、二进制内容冲突以及混合冲突展示类型并保留原状态，不用文本策略代替处理。
- 冲突信息从公开 API 获取。将来预览可调用 `svn_client_conflict_text_get_contents`，并处理缺失内容。P0 不把临时内容路径持久化进状态，也不从 `.mine`、`.rN` 或 `.svn/pristine` 猜测内容。
- 解析或读写失败沿用现有错误通道。若操作后仍有冲突则明确报告剩余类型。用户取消时保持文件和冲突元数据。

| 策略 | 界面文案 | libsvn 选项 |
|---|---|---|
| `current` | 采用工作文件当前内容 | `svn_client_conflict_option_merged_text` |
| `base` | 采用此冲突的基线内容 | `svn_client_conflict_option_base_text` |
| `incoming` | 采用传入版本（更新来源或合并源） | `svn_client_conflict_option_incoming_text` |
| `local` | 采用冲突发生前的本地版本 | `svn_client_conflict_option_working_text` |

[Apache Subversion 冲突 API](https://subversion.apache.org/docs/api/latest/svn__client_8h.html)

## P0.3 指定修订合并

- **输入**为源 URL、目标工作副本根、修订与可选 peg。单修订 `N` 转换为 `(N-1,N]`；范围 `A:B` 表示 `(A,B]`。校验数字及 C ABI 可表示范围，禁止同时传单修订与范围。默认用范围终点作为 peg；需要按改名前路径定位时，显式指定适用的 peg。始终传明确范围，避免 `NULL` 触发自动合并。
- **执行条件**为同仓库 UUID、同认证端点、干净且单一修订的目标工作副本。拒绝已有冲突、未提交改动、切换子树、稀疏工作副本及 P0 无法安全处理的外部工作副本。保留祖先关系和 mergeinfo 检查，关闭强制删除及允许混合修订选项。源端只读，沿用工作副本绑定的凭据与证书约束。
- **预演**通过 `dry_run` 和通知回调收集预计改动、跳过和冲突；预演结果以预计状态展示，不能靠事后 `status` 推导。GUI 先预演再确认应用。应用前重查目标状态并使用同一组输入；实际结果以应用后的通知和状态为准。
- **应用**修改本地内容和可能的 `svn:mergeinfo`，由 libsvn 维护。结果记录模式、请求范围、实际或预计改动、冲突、跳过项及是否需要刷新。无需返回「合并后 BASE 修订」。确认后进入 Changes，展示文件与属性变化。提交前显示包含 mergeinfo 的完整范围，避免只提交内容丢失合并记录，或以递归目录提交带入未审核的改动。
- **失败恢复**区分预检拒绝、执行失败和应用后状态刷新失败。应用中途失败可能已改变工作副本，必须重新查询并展示实际状态，保留修复或定向放弃的入口。回滚前展示路径和影响，保留用户随后新增或修改的文件。GUI 不自动递归 revert。

[Apache Subversion 合并 API](https://subversion.apache.org/docs/api/latest/group__Merge.html)

## 接口和界面约定

- **协议与类型**：在 `RepositoryClient` 同一轮补齐现有通用 `add`、`cat` 和新增能力，保留现有调用签名。新增协议要求可有默认的不支持实现，保证已有 conformer 可编译。合并或冲突涉及 SVN 专属参数时使用显式选项类型；不以此宣称 GUI/CLI 已能切换后端。新增工作副本操作返回本地结果或受影响路径，不复用远端提交结果。仅按需要增加移动关系、冲突种类等可选状态。
- **C 与 Swift**：复用私有执行队列、上下文互斥锁、scratch pool、错误映射和释放规则。临时替换通知回调时确保每条返回路径恢复回调和 baton。涉及同一工作副本的写操作与关键预检需要互斥，不能只依赖单个 `SVNClient` 的队列。GUI 在操作开始时捕获工作副本、路径和参数，限制并发写操作，丢弃针对已切换视图或工作副本的旧结果。
- **GUI**：沿用 `AppModel`、Changes、WorkingDiff 与工作副本工具栏。沿用现有的 `Theme`、确认和错误展示。合并结果独立保留，用户可以查看预演、冲突与部分失败。交付时更新中英 README、命令帮助及单独的前端集成说明，列出参数、结果、调用顺序、错误及界面适配。
- **范围取舍**：显示更新冲突属于 P0。锁拥有者展示、未使用方法清理和主题重构单独评估，避免与行为改动混合。

计划中的 CLI 形态如下。

```text
vcsctl delete <工作副本> <路径> [路径...]
vcsctl move <工作副本> <源相对路径> <目标相对路径>
vcsctl rename <工作副本> <源相对路径> <新文件名>
vcsctl copy <工作副本> <源相对路径> <目标相对路径>
vcsctl resolve <工作副本> <路径> --strategy current|base|incoming|local
vcsctl merge <工作副本> --source <URL> --revision N [--peg N] [--dry-run]
vcsctl merge <工作副本> --source <URL> --from A --to B [--peg N] [--dry-run]
```

CLI 为带值参数登记解析规则，并校验缺值、重复参数、未知策略和冲突选项。明确区分成功无冲突、留下未解决冲突和执行错误。新增 `merge` 可用退出码 `0/2/1` 区分，预演使用相同约定报告预计冲突。既有 `update` 的退出码保持兼容，保留冲突列表输出。

## 实施与验收

| 顺序 | 独立提交建议 | 关键验收 |
|---|---|---|
| 1 | `feat(svn): add working copy file operations` | 普通已纳管文件能从 GUI 操作。删除、移动、复制后 SVN HEAD 保持原值。显式提交后核对路径与 `copyfrom`。验证移动成对提交和放弃、目标已存在、被修改文件删除、路径逃逸、根路径及特殊文件名。 |
| 2 | `feat(svn): surface and resolve working copy conflicts` | A、B 两个工作副本修改同一基线文件的同一行。先提交 B，再更新尚未提交的 A，先确认真的产生冲突。四种策略分别用独立夹具校验文件内容及冲突是否清除。属性、树、混合冲突仍可见，且文本按钮无法误处理。 |
| 3 | `feat(svn): preview and apply revision merges` | 同仓库两分支验证单修订、范围、无 eligible 变更、文本冲突、拒绝脏目标或混合修订。对预演前后比较文件内容、`svn status`、`svn:mergeinfo` 与仓库 HEAD。验证实际应用后 HEAD 仍不变，提交时同时带上预期内容和 mergeinfo。 |
| 按需独立 | `test: harden temporary SVN fixtures` | 现有脚本已使用 `mktemp` 和退出清理。只改实际复现的问题，例如重复删除新目录或夹具初始化失败未立即终止。清理只针对本次创建并验证过的目录。 |

每个功能提交跑对应单元与端到端回归，新增单元用例登记进 harness 的 `main()`。P0 交付时跑完整基线并按行为用例验收，不用断言总数代替覆盖。

```bash
source scripts/svn_build_env.sh
swift build
swift run SwiftVCSChecks
./Tests/run_e2e.sh
python3 Tests/run_security.py "$(swift build --show-bin-path)/vcsctl"
```

- 回环安全回归继续覆盖凭据、指纹与端点边界。新增合并验证时分别记录认证与请求方法，确认源端只收到读取所需请求。验证工作副本本地文件操作无需访问远端，不能用「请求未通过认证」替代「没有发起仓库写入」。
- GUI 手工验收使用隔离工作副本，覆盖操作可达性、取消、失败后状态、冲突选择、预演与实际合并的文案。CLI 或模型自检只证明其覆盖的入口。
- 沿用现有 CI 和打包验证，检查解包后主程序及内置 dylib 的加载路径、架构和签名。产物的最低系统版本由实际动态库决定。远端 CI、Developer ID 公证与目标系统实机验收分别记录。
- 保留 `CSVNDependencies` 的 pkg-config 构建路径。裸 `swift build` 的易用性单独评估；改动前后用独立 SwiftPM 消费项目复验，避免重新引入会导致下游拒绝的 `unsafeFlags`。

## 后续路线

下一阶段的实施范围、依赖和验收见 [SwiftVCS 下一阶段功能计划](NEXT_STAGE_PLAN.md)。

| 优先级 | 事项 |
|---|---|
| P1 代码洞察 | blame、日志按作者或日期筛选、仓库搜索、目录树版本对比。日志已有路径过滤；树差异需比较两个端点，不能直接拼接中间提交的 changed paths。 |
| P2 工作副本与仓库管理 | 目录级文件操作、仓库端直接操作、树与属性冲突解决、三方预览、switch、relocate、cleanup、export、properties、externals、ignore、patch、锁、changelist 和多工作副本。分别定义工作副本与 URL 操作语义。 |
| P3 后端扩展 | 评估真正切换后端所需的能力模型和调用方改造，再确定 Perforce、Git 接入范围。 |
| P4 工程与体验 | 构建入口易用性、GUI 自动化、视觉预览、测试边界扩充、通用界面文档。 |
