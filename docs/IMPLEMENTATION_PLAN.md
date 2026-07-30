<spec-entry category="arch" keywords="swiftui,swiftdata,import-pipeline,reader-architecture,github-actions" date="2026-07-30" source="grilling-session-2026-07-30">

# ComicReader 分阶段技术实施计划

## 1. 实施原则

- 采用小步、可测试、可回滚的增量交付。
- 每个里程碑结束时必须具备可安装、可导入、可阅读的工作版本。
- 先建立领域模型和导入测试接缝，再编写 UI。
- 用户原始目录始终只读；所有修改发生在 App 管理目录和数据库。
- 所有文件 I/O、哈希和图片解码使用结构化并发，不阻塞 MainActor。
- 在仓库形成稳定模式前不引入不必要的抽象或第三方依赖。

## 2. 建议工程结构

### App

负责 App 生命周期、Scene、多窗口、依赖装配、路由、全局命令和隐私锁。

### Domain

包含不依赖 UI 或 Apple 持久化实现的领域模型与规则：

- Comic、Collection、Chapter、Page；
- SourceReference、ContentFingerprint；
- ReadingPosition、ReadingDirection、ReadingMode；
- ImportManifest、ImportIssue、ImportJob；
- 自然排序、封面选择、跨页判定和冲突合并策略。

### Importing

负责来源授权、递归扫描、内容嗅探、预览、空间估算、复制、验证、提交、取消和恢复。

### Library

负责书库查询、搜索、筛选、书架、元数据编辑、最近删除、导出和索引重建。

### Reader

负责单页、双页、连续滚动布局，渐进解码、缓存、手势、键盘命令、导航及进度采集。

### Persistence

负责 SwiftData Schema、文件布局、迁移、事务边界、CloudKit 同步适配和诊断。

### SharedUI

负责可复用控件、空状态、错误状态、进度视图、无障碍语义和本地化资源。

### TestSupport

负责临时漫画目录生成、测试图片生成、Fake File Provider、Fake Cloud Store、可控时钟和故障注入。

## 3. 核心数据模型

### Comic

- 稳定 UUID；
- 显示标题与原始根目录名；
- 作者、简介、标签、状态和收藏；
- 封面 Page ID 或自定义封面；
- SourceReference 与内容指纹；
- 导入、更新、最近阅读和删除时间；
- 默认阅读模式与方向覆盖。

### Collection

- 稳定 UUID；
- Comic ID；
- 父 Collection ID；
- 原始名称、显示名称、相对路径和排序键。

Collection 表达任意深度的卷或分组，不把目录层级硬编码成固定的“卷”。

### Chapter

- 稳定 UUID；
- Comic ID 与父 Collection ID；
- 原始名称、显示名称、相对路径和排序键；
- 内容摘要、页数、导入状态和来源缺失状态；
- 用户页序覆盖和已读状态。

### Page

- 稳定 UUID；
- Chapter ID；
- 原始文件名、来源相对路径、内部相对路径；
- 媒体类型、字节数、像素尺寸、方向和内容摘要；
- 默认顺序、用户顺序、解码状态和错误信息。

### ReadingProgress

- Comic、Chapter 和 Page ID；
- Page 内归一化偏移；
- 缩放比例与可选视口中心；
- 阅读模式、方向和更新时间；
- 明确的已读／未读操作版本。

### ImportJob

- Job ID、来源书签和目标 Comic ID；
- 当前状态、进度、总字节数和已复制字节数；
- Manifest 版本；
- 待处理、已完成和失败工作项；
- 暂存目录、最后更新时间和取消标记。

## 4. App 管理目录布局

```text
Application Support/
├─ Library/
│  └─ <comic-id>/
│     ├─ original/
│     │  └─ <chapter-id>/<page-id>.<preserved-extension>
│     └─ metadata/
├─ Imports/
│  └─ <job-id>/                 # 可恢复暂存区
├─ Thumbnails/                  # 可重建，排除备份
├─ RenderCache/                 # 可重建，排除备份
└─ Diagnostics/                 # 仅匿名、可主动导出
```

- 原图目录使用数据保护，并排除 iCloud 设备备份。
- 缓存使用容量与最近使用时间双重淘汰。
- 数据库只存相对路径，不保存可泄露的用户绝对路径。

## 5. 目录识别算法

### 5.1 Scan

1. 取得 security-scoped access。
2. 枚举目录项，不跟随符号链接，跳过隐藏和系统文件。
3. 对普通文件读取有限头部字节，使用 ImageIO／UTType 验证类型和可解码性。
4. 收集像素尺寸、方向、字节数和轻量指纹；完整哈希延迟到复制阶段。
5. 每个含候选图片的目录生成 Chapter Candidate。
6. 每个不含图片但包含有效后代的目录生成 Collection Candidate。
7. 应用自然排序、封面规则及异常分类。
8. 生成不可变 ImportManifest 供预览和后续复制使用。

### 5.2 Preview

- 展示目录树、封面、页数、忽略项、错误项和空间估算。
- 允许修改显示名、封面、章节启用状态和顺序。
- 用户确认后冻结 Manifest 修订版本，避免复制阶段结构漂移。

### 5.3 Copy

1. 为 Job 建立独立暂存目录。
2. 按 Manifest 工作项复制原始字节。
3. 每项复制后核对大小与内容摘要。
4. 持久化完成状态，再处理下一项。
5. 取消或进程退出时保留已验证工作项。

### 5.4 Verify and Commit

1. 对每章验证页清单和可读性。
2. 在数据库事务中写入新模型或更新映射。
3. 将已验证暂存目录原子移动至正式目录。
4. 提交数据库事务并生成基础缩略图。
5. 任何提交失败均保持旧版本可用，并保留可诊断状态。

### 5.5 Incremental Update

- 优先使用来源书签身份和相对路径定位已有漫画与章节。
- 文件大小、修改时间仅用于快速筛选，最终变化判断使用内容摘要。
- 新章节进入 Add 集合，内容变化进入 Replace 集合，来源缺失进入 Missing 集合。
- Replace 先建立完整新章，成功后交换引用，再异步清理旧章。
- 用户页序通过 Page 内容摘要和原始相对路径尽量迁移。

## 6. Reader 架构

### ReaderSession

单个窗口维护独立 ReaderSession，包含当前漫画、章节、页面、布局、视口和工具栏状态。领域进度写入通过节流事件完成；进入后台、关闭窗口或切换章节时立即刷新。

### Layout Strategies

- ContinuousLayout：纵向 Lazy 容器，按可见区域解码。
- SinglePageLayout：分页容器，每屏一页。
- SpreadLayout：封面独立，普通竖页按方向配对，横向图独占一屏。

布局策略共享 Page Presentation Model 和进度协议，避免 3 套独立阅读状态。

### Image Pipeline

1. 立即读取磁盘缩略预览。
2. 按显示尺寸使用 ImageIO downsampling。
3. 必要时对超大图片使用分块或分段渲染。
4. 缓存已解码邻页，数量根据窗口、滚动速度和内存压力调整。
5. 收到内存告警时清空非可见解码缓存，不删除磁盘原图。

### Input

- SwiftUI Gesture 与必要的 UIKit 手势协调处理缩放、拖动和点击区域。
- `Commands` 提供键盘快捷键。
- 边缘退出手势与分页手势通过明确优先级避免冲突。
- 所有功能必须有非手势入口，满足可发现性和无障碍要求。

## 7. Persistence 与同步

### Local

- SwiftData 是模型事实来源，文件系统保存大对象。
- Schema 从第一个提交开始版本化。
- 迁移前生成轻量数据库备份；失败时进入只读恢复状态。
- 提供从内部文件结构重建索引的维护用例。

### CloudKit

- 仅同步轻量模型，不同步文件 URL、原图、缩略图或诊断。
- 使用稳定 Comic ID；没有元数据 ID 时使用 Manifest 指纹提出匹配建议。
- ReadingPosition 使用更新时间较新值。
- 已读集合使用合并语义；显式“标记未读”带操作版本以覆盖。
- CloudKit 不可用时写入本地 outbox，恢复后重放。

## 8. 分阶段执行

## M0：仓库与工程基线

### Deliverables

- 初始化 Git 仓库和公开项目基础文件。
- 创建仅 iPad、最低 iPadOS 17 的 SwiftUI 工程。
- 添加 MIT License、README、贡献指南和第三方许可证清单。
- 建立 Domain、Importing、Library、Reader、Persistence 和 TestSupport targets／groups。
- 配置 SwiftLint 或等价静态规则；如需第三方工具，固定版本。
- 建立 Unit Test、UI Test 和性能测试 Scheme。

### Verification

- Debug 与 Release 均可在本地和 CI 无签名编译。
- 空白 App 可在 iPad Simulator 启动。
- Pull Request 工作流能执行编译和测试。

## M1.1：领域模型与识别引擎

### Deliverables

- 实现目录树、候选图片、Manifest、Issue 和自然排序模型。
- 实现内容嗅探、隐藏文件规则、软链接规则和坏图分类。
- 实现任意层级 Collection／Chapter 识别。
- 实现封面选择、重复提示和空间估算。
- 建立可编程 Fixture Builder。

### Verification

- 覆盖根目录散页、单层章节、多层卷／话、混合图片与子目录。
- 覆盖无扩展名、错误扩展名、8 种支持格式及不支持文件。
- 覆盖空目录、坏图、软链接循环、Unicode 和自然排序。

## M1.2：导入预览与可恢复复制

### Deliverables

- 系统文件夹选择、多选和拖放。
- 来源 security-scoped bookmark 管理。
- 导入预览、章节勾选、封面与排序调整。
- ImportJob 状态机、暂存目录、空间检查、取消和恢复。
- 导入报告和基础缩略图。

### Verification

- 注入复制失败、空间不足、权限丢失和进程中断。
- 确认重新启动可继续且不会重复提交。
- 确认批量导入单本失败不影响其他任务。
- 确认来源目录从未发生写入。

## M1.3：基础书库

### Deliverables

- 书库网格、漫画详情、Collection／Chapter 树。
- 继续阅读、最近导入和基础收藏。
- 数据库迁移基线和索引重建入口。

### Verification

- 导入完成后无需重启即可出现。
- 删除数据库索引的测试副本后可从内部文件重建。
- 1,000 本虚拟书库查询和滚动满足性能预算。

## M1.4：3 种阅读模式

### Deliverables

- Continuous、SinglePage 和 Spread 共享 ReaderSession。
- 左右方向、封面独立、横向跨页判断。
- 渐进图片加载、缩放、拖动、页面占位和邻页预取。
- 页面、章节及页面内偏移进度保存。
- 工具栏、页码、进度条、章节导航和基础键盘操作。

### Verification

- 覆盖奇偶页、左右方向、旋转、Split View 和超大图片。
- 冷启动恢复具体页面及页面内位置。
- 快速翻页和连续滚动不在主线程同步解码。

## M1 Exit Criteria

- 可从 Files 导入真实文件夹并稳定阅读。
- 所有 M1 自动化测试通过，核心模块覆盖率达到 80%。
- 无 P0／P1 数据丢失、导入损坏或阅读崩溃问题。
- `main` 构建可生成测试用未签名 IPA Artifact。

## M2.1：增量更新与版本管理

- 实现同来源扫描、Add／Replace／Missing 差异预览。
- 实现安全章节替换、来源重授权和手动缺失清理。
- 实现不同来源独立及用户主动版本合并。
- 实现整话反序和单页拖动排序迁移。

## M2.2：完整书库管理

- 搜索、筛选、排序、自定义书架和元数据编辑。
- 最近删除、30 天清理、永久删除和原结构导出。
- 自定义封面、阅读状态和完整导入历史。

## M2.3：完整 iPad 体验

- 多窗口、Stage Manager、外接显示器和完整快捷键。
- Face ID／设备密码锁及多任务快照保护。
- 亮度、背景、留白裁切、旋转、常亮和动画设置。
- 简体中文、英文、VoiceOver、Dynamic Type、高对比度和降低动态效果。

## M2 Exit Criteria

- 本地功能与 PRD 中除 iCloud 外的需求全部完成。
- 多窗口同时阅读和更新不会破坏进度或文件。
- 最近删除、导出、更新和索引恢复通过故障注入测试。

## M3.1：iCloud 元数据同步

- 配置 CloudKit 容器和同步 Schema。
- 实现 outbox、离线恢复、进度冲突和已读集合合并。
- 实现稳定 ID 元数据导出及低置信度匹配确认。

## M3.2：性能与可靠性硬化

- 生成 100,000 页级测试库并建立性能基线。
- 优化扫描并发、哈希策略、缩略图队列和查询索引。
- 执行内存告警、磁盘满、迁移失败、云端错误和长时间后台恢复测试。
- 使用 MetricKit 与匿名诊断确认热点，不加入行为分析。

## M3.3：公开发布工程

- 完成 README、架构说明、隐私说明、依赖许可证和贡献流程。
- 配置 `main` Artifact 与 `v*` GitHub Release 工作流。
- 生成未签名 IPA、dSYM 和构建信息。
- 验证公开日志和 Artifact 不包含路径、内容或凭据。

## 9. 测试矩阵

| 层级 | 主要对象 | 关键场景 |
|---|---|---|
| Unit | 排序、识别、封面、跨页、指纹、冲突 | 边界、Unicode、坏输入、确定性 |
| Integration | ImportJob、文件事务、SwiftData、迁移 | 中断、回滚、恢复、空间不足 |
| UI | 导入预览、书库、阅读、删除恢复、隐私锁 | 用户主路径和无障碍 |
| Performance | 扫描、缩略图、查询、滚动、翻页 | 100,000 页、超大图、内存压力 |
| CI | 编译、测试、静态检查、Artifact | PR、main、Tag 三种触发 |

### Test Fixture Families

- `FlatSingleChapter`：根目录直接包含图片。
- `NestedVolumes`：多卷、多话、任意深度。
- `MixedContent`：图片、子章节、封面和非图片混合。
- `MisleadingExtensions`：扩展名错误或缺失。
- `CorruptedPages`：部分和全部损坏。
- `IncrementalVersions`：新增、修改、缺失和不同来源。
- `HugeLibrary`：按参数生成海量元数据与小型图片。

## 10. GitHub Actions 设计

### Pull Request

- 选择固定 Xcode 主版本。
- 解析锁定依赖。
- 无签名构建 Simulator 目标。
- 执行 Unit Tests、UI 冒烟测试、静态检查和覆盖率门槛。
- 不生成长期 IPA。

### main

- 执行完整测试。
- 使用 Release 配置构建未签名 `.app`。
- 将 `.app` 置入 `Payload/` 并打包为未签名 IPA。
- 归档 dSYM 和构建信息，作为短期 Actions Artifact。

### Version Tag

- 对 `v*` Tag 重复可复现 Release 构建。
- 生成版本化未签名 IPA、dSYM、校验和与构建信息。
- 创建 GitHub Release 并附加产物。
- 不导入证书、Provisioning Profile 或任何签名 Secret。

### Build Metadata

- App 版本和构建号；
- Git commit SHA 和 Tag；
- 构建 UTC 时间；
- Xcode 与 Swift 版本；
- 锁定依赖摘要；
- IPA 与 dSYM 校验和；
- 明确标注 `unsigned`。

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 云盘文件尚未下载或权限失效 | 扫描或复制中断 | 可恢复任务、重试、重新授权、明确报告 |
| 超大图片造成内存峰值 | 阅读崩溃 | 降采样、分块、邻页自适应缓存、内存告警清理 |
| SwiftData／CloudKit Schema 限制 | 同步或迁移失败 | 云端只放轻量模型、版本化 Schema、先做本地事实来源 |
| 来源结构变化导致错误更新 | 章节错配 | 来源身份 + 相对路径 + 内容摘要，更新前展示 Diff |
| 公开 CI 泄露敏感信息 | 隐私问题 | 无签名 Secret、日志脱敏、Artifact 内容自动审计 |
| 多窗口同时写进度 | 位置竞争 | 每 Scene 独立 Session、带时间戳事件、集中 Repository 合并 |
| 功能范围较大 | 首版延期 | M1／M2／M3 硬边界，每阶段独立验收 |

## 12. Definition of Done

每个功能只有同时满足以下条件才算完成：

- 对应用户故事和验收条件已实现。
- 正常、边界和错误路径自动化测试通过。
- 公共行为有文档，新增术语与现有领域语言一致。
- 不在主线程执行阻塞 I/O 或完整图片解码。
- VoiceOver 标签、本地化键和隐私影响已检查。
- 数据迁移、取消、重试和恢复行为已经验证。
- CI 在 Pull Request 上通过，且没有新增敏感日志或未记录依赖。

## 13. 首个实施切片

建议第一个代码切片只交付：

1. 纯 Domain 的目录识别模型；
2. TestSupport 临时目录与测试图片生成器；
3. 对根目录散页、嵌套卷／话、混合内容和错误扩展名的测试；
4. 一个命令式 ImportScanner 接口及可观察 ImportManifest；
5. 最小 SwiftUI 调试页，用系统文件夹选择器展示识别结果，不复制文件。

该切片建立全项目最高层测试接缝，并在引入持久化和复杂 UI 前验证最关键的“自动识别格式”能力。

</spec-entry>
