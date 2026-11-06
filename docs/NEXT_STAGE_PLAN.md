# SwiftVCS 下一阶段功能计划

计划日期为 2026-11-07。实施基线为本地 `main` 的 `cd8c5f3`，本机 Subversion 为 1.15.0。P0 已随 `7238fef` 提交，UTF-8 错误、无调用的 diff 方法、锁持有者展示、直接构建入口和测试清理均已处理。此前本地通过了 5 项单元检查、45 项基础端到端断言、P0 验收和回环安全测试。远端 CI 结果仍需核验。

**首批已在本地实现节点属性读取、本地属性编辑、忽略规则和工作副本建目录。** 优先打通普通文件、目录及工作副本根的实际操作路径。锁、变更组、冲突深化和仓库端写入分别验收。原稿的人日和覆盖百分比缺少可复核口径，待首批功能验收后再估算后续工作。

## 操作语义和共用边界

| 操作类别 | 示例 | 结果和用户提示 |
|---|---|---|
| 查询 | 属性、日志、blame、树对比、mergeinfo | 返回数据、来源、查询范围和截断信息 |
| 本地版本化变更 | 工作副本建目录、属性修改、应用补丁或合并 | 工作副本立即变化，显式提交后才产生仓库修订 |
| 本地管理或输出 | cleanup、changelist、switch、relocate、upgrade、export | 返回本地结果和失败影响范围。管理元数据、切换目标或写出文件本身不创建仓库修订 |
| 仓库提交 | URL 建目录、删除、复制、移动、节点属性写入、import | 返回提交回调确认的实际修订。操作前展示目标、范围和提交说明 |
| 仓库即时变更 | lock、unlock、修订属性写入 | 仓库状态立即变化，HEAD 不增加。锁返回逐目标结果，修订属性返回受影响的已有修订 |

本地路径与仓库 URL 采用各自的接口和参数。保留已有 `RepositoryClient` 调用方式，新能力可以提供抛出 `notSupported` 的默认实现。含过滤条件的写入缺少后端支持时直接报错，避免退回无过滤提交。C 层沿用公开 libsvn API、scratch pool、通知回调与错误转换。工作副本写入沿用 `runWorkspaceWrite`、`clientForWorkingCopy()` 和进程内写入互斥，捕获操作目标并重新校验工作副本归属。仓库访问继续约束认证端点、凭据及证书。写入、切换和迁移用临时仓库验收。

## 首批可实施规格

### 1. 节点属性与忽略规则

- **读取**。用 `svn_client_proplist4` 列表、`svn_client_propget5` 读取单项。工作副本默认读当前值，仓库 URL 默认读 HEAD，历史查询区分 peg 与操作修订。先支持单目标和可选的继承属性。回调接收属性哈希和继承项数组，须在 scratch pool 释放前复制。属性值按字节和长度传递，用 `Data` 表达并区分未设置、空字节串和非 UTF-8 内容。列表身份用目标、来源和属性名，避免不同祖先的同名属性覆盖。继承列表展示声明来源，有效值按具体属性的 SVN 规则判定。
- **本地编辑**。用 `svn_client_propset_local`，默认 `svn_depth_empty`、`skip_checks=false`。设置与删除是明确的动作，空值与传 `NULL` 删除分别处理。首版开放自定义属性，以及经类型校验的 `svn:ignore`、`svn:eol-style`、`svn:keywords`、`svn:mime-type`。继承行和 `svn:mergeinfo` 只读，`svn:externals`、`svn:auto-props` 与 `svn:global-ignores` 等行为型属性先只读展示。后两者属于可版本化的节点属性，首版只读是产品范围选择。
- **忽略规则**。`svn_wc_get_default_ignores` 读取配置默认模式，分别展示目录直接设置的 `svn:ignore` 与沿祖先继承的 `svn:global-ignores`。祖先的 `svn:ignore` 可以出现在继承属性列表，但不会因此忽略子目录中的文件。验收需检查 SVN 状态分类，默认列表隐藏忽略项的显示行为单独核对。
- **界面和 CLI**。「更改」和工作副本菜单提供属性入口，覆盖正常文件、目录及根目录；仓库浏览提供只读入口。CLI 提供 `proplist`、`propget`、`propset`、`propdel`。工作副本读取和编辑使用相对路径，URL 仅用于读取。CLI 用 `propget --raw` 将单个属性原始字节写到 stdout，诊断走 stderr；`propset --file` 可为自定义属性读入字节。文本编辑器只处理可编辑文本值。应用后刷新状态，提示属性改动待提交。
- **验收**。对照 `svn proplist --show-inherited-props` 与 `svn propget` 检查来源和值。覆盖空值、含 NUL 的自定义属性、同名祖先属性、读取历史修订、只读属性、越界路径和正常节点。设置或删除后 HEAD 不变，提交后再用新检出验证。忽略夹具分别验证父目录 `svn:ignore` 仅作用于直接子项、`svn:global-ignores` 影响后代，已纳管文件的状态不会因为命中忽略模式而消失。

[Apache Subversion 属性接口](https://subversion.apache.org/docs/api/latest/group__svn__client__prop__funcs.html)

### 2. 工作副本建目录

- 用 `svn_client_mkdir4` 的本地路径分支。只接受已核验工作副本根下的相对路径，校验最近存在的父目录、符号链接和嵌套工作副本归属。目标存在即提示。默认只建指定目录，`--parents` 显式开启，并在 GUI 显示将新增的中间目录。
- 在工作副本菜单提供「新建目录」，CLI 提供 `mkdir <工作副本> <相对路径> [--parents]`。返回实际新增路径，刷新状态并显示待提交。验收覆盖普通目录、缺失父目录、重复路径、越界路径、部分失败后的状态和放弃变更。确认 HEAD 在显式提交前保持不变。

## 后续阶段与验收门槛

| 阶段 | 能力与接口 | 实施前须落实 |
|---|---|---|
| 工作副本维护 | `svn_client_cleanup2`、`svn_client_lock` / `unlock`、changelist、递归列举 | cleanup 区分正常清理与解除残留工作副本锁，默认不处理 externals 或清除未纳管文件。解除残留锁前确认无其他 SVN 操作。仓库锁以 token 持有状态区分当前副本能否正常解锁，锁拥有者名称仅用于展示；逐路径区分成功、失败、未尝试。抢锁与强制解锁延后。changelist 用 `svn_client_add_to_changelist`、`remove_from_changelists` 和 `get_changelists`，只分组文件。状态与提交都传实际过滤条件，测试移动两端分属不同组、组外路径和 mergeinfo 的提交约束。递归列举优先 `svn_client_list4`，设置深度、返回数量和取消边界。 |
| 冲突深化 | `svn_client_conflict_text_get_contents`、属性和树冲突的各自选项 API | 先做有大小上限的只读预览。文本 API 的四个槽位是基线、冲突前本地、传入旧版、传入新版；磁盘当前工作内容单独读取。缺失与空内容分开，复用现有两栏视图做两组比较。树冲突详情可能访问仓库，选项按当前冲突重新获取并处理候选移动目标。属性按名称使用属性专属选项，树使用树专属选项。每次解决后复查剩余冲突。自动接受更新冲突延后，保留默认暂缓，不递归处理此前已有的冲突。 |
| 代码洞察 | `svn_client_blame6`、`svn_client_log5`、`svn_client_diff_summarize2` / peg 变体、mergeinfo 查询 | blame 用 libsvn 默认 diff 选项，标注未知修订和本地行；行数上限限制展示，仍需独立限制版本跨度和支持取消。当前日志已请求作者、日期和说明，并支持路径、分页和已加载条目搜索。新查询保留旧接口，以原始扫描位置推进游标，分别定义扫描上限、命中上限和停止原因；验证零命中仍可继续分页。树对比返回端点的增删改和属性变化，摘要本身不提供 copyfrom。`svn_client_mergeinfo_get_merged` 读取记录范围，`svn_client_mergeinfo_log2` 查询指定源的已合并或可合并修订。 |
| 切换、导出与迁移 | `svn_client_switch3`、`svn_client_relocate2`、`svn_client_export5`、`svn_client_upgrade2`、`svn_client_patch` | switch 可能保留或合并本地修改，首版由应用预检干净目标，成功后更新当前仓库 URL 与上下文并刷新。relocate 校验同一仓库 UUID 与前缀边界，跨端点重新认证和核验证书。export 首版用新目标路径，默认忽略 externals。upgrade 先评估格式兼容和备份，NULL 表示库默认格式，且调用可递归处理 externals。patch 的回调筛选目标文件，hunk 是否拒绝依据通知；预演校验越界路径，应用后展示部分成功和拒绝项。 |
| 仓库级操作与修订属性 | URL mkdir/delete/copy/move、`svn_client_propset_remote`、`svn_client_import5`、revprop 查询和编辑 | 使用单独入口，执行前显示范围和提交说明，成功修订以提交回调为准。分支和标签优先单次 URL copy，缺父目录时显式开启 `make_parents`。import 预览将包含的本地文件，遵守忽略和自动属性规则。revprop 写入后 HEAD 不增，要求服务端权限和 hook；使用旧值条件写，只有服务端支持原子修订属性能力时才声称原子，并测试并发修改、无 hook 和权限不足。 |
| 高级合并 | `svn_client_suggest_merge_sources`、`svn_client_get_merging_summary`、`svn_client_merge_peg5` | 来源建议和摘要先作为只读功能，候选 URL 不等于建议的修订范围。自动合并用 `ranges_to_merge=NULL`，不新接废弃的 `svn_client_merge_reintegrate`。反向用显式方向和递减范围，保留 P0 正向请求校验。自动与反向合并均需预演，应用后验证内容、冲突和 mergeinfo，并回归原有精确提交。 |

工作副本建目录、基础维护、冲突只读预览和代码洞察可以分别推进。只有实际需要读取或编辑属性的功能才依赖首批属性能力；高级合并不依赖树对比。目录级操作、外部工作副本和批量破坏性写入各自定义范围，不随着新增 API 自动开放。

[Apache Subversion 客户端公开头](https://subversion.apache.org/docs/api/latest/svn__client_8h_source.html) · [Apache Subversion 合并接口](https://subversion.apache.org/docs/api/latest/group__Merge.html)

## 原稿中已核正的关键事项

| 原稿判断 | 核正结果 |
|---|---|
| `svn_proplist_receiver2_t` 每次回调一项属性 | 签名为 baton、路径、属性哈希、继承项数组、scratch pool。按名称和来源展开，值按显式长度复制。 |
| `propset3` 统一调度与提交，使用一个 `CommitResult` | 该接口已弃用。工作副本与 URL 分别采用 `propset_local` 与 `propset_remote`，区分本地结果和实际提交结果。 |
| 修订属性立即提交、默认仓库可写 | 它修改既有修订且不产生新修订。临时仓库未配置 hook 时拒绝；启用测试 hook 后能修改，HEAD 保持不变。 |
| 分支需先建目录再复制，共两次提交 | 临时仓库使用 URL copy 和 `--parents`，父目录及分支在同一次提交出现，且保留 `copyfrom`。 |
| 已有日志完全无过滤、部分修订属性未取 | 已有路径过滤、分页和 GUI 对已加载条目的关键词过滤，C 层已请求 `svn:log`、`svn:author`、`svn:date`。缺口是有边界的跨页查询。 |
| 现有信任流程合并 CA bundle 并全局写 `SSL_CERT_FILE` | 当前按 HTTPS 主机和端口保存叶证书 pin，口令按仓库 URL、用户名和认证域隔离。当前检出用 `checkout3`，读取文件用 `cat3`，仓库识别走 RA 会话。 |
| 公开头没有 diff3/diff4，patch 回调拒绝单个 hunk | 公开 `svn_diff.h` 有 diff3/diff4 接口，是否采用另行评估。patch 回调过滤目标文件，实际应用和拒绝结果从通知读取。 |

## 验收与交付

- 每批按现有 C shim、CSVNKit、协议、AppModel、GUI/CLI 的路径交付。测试先覆盖行为及失败边界，再运行现有基线。新增单元用例登记到 `SwiftVCSChecks.main()`，GUI 实机验收与模型自检分别记录。
- 写入验收核对本地和仓库两侧的结果。仓库修订增量只在专用夹具、没有其他写入者且操作确实提交时断言；对锁和修订属性还要检查锁记录或实际属性值。安全套件以请求方法和服务端状态判断副作用，认证是否成功单独记录。
- 首批完成后更新中英文使用文档及独立前端集成说明。后续提交按功能切片，沿当前 `main` 使用 Conventional Commits。GitHub CI、独立包和其他 macOS 版本的结果分别记录。

```bash
./scripts/svn_build_env.sh
source scripts/svn_build_env.sh
swift run SwiftVCSChecks
./Tests/run_e2e.sh
python3 Tests/run_security.py "$(swift build --show-bin-path)/vcsctl"
```

`run_e2e.sh` 运行 P0 验收和 `run_properties.py`。新验收用临时仓库验证原始字节、空值、继承、历史修订、忽略分类、精确提交、路径边界及建目录回滚。界面已在隔离的本机应用点验正常文件、工作副本根目录、仓库只读属性和建目录预览；外部操作改变待创建路径后，旧预览会被拒绝。后续阶段尚未实施。
