# ComicReader

ComicReader 是一款面向 iPad 的免费、本地优先漫画阅读器。目前项目正在按 M0–M3 里程碑逐步开发，尚未提供稳定版本。

## 产品目标

- 从“文件”App 可访问的位置导入一个或多个漫画文件夹；
- 自动识别“漫画 → 卷／分组 → 话 → 图片”等任意深度目录；
- 根据文件内容识别 JPEG、PNG、WebP、HEIC／HEIF、GIF、BMP 和 TIFF，不依赖扩展名；
- 保留原始图片质量与文件名，将内容复制到 App 管理的本地资料库；
- 提供纵向连续、横向单页和横屏双页 3 种阅读模式；
- 支持自然排序、阅读进度恢复、左右阅读方向及 iPad 多任务体验。

完整范围与技术方案见：

- [产品需求文档](docs/PRD.md)
- [分阶段技术实施计划](docs/IMPLEMENTATION_PLAN.md)

## 平台与原则

- 仅支持 iPad，最低版本为 iPadOS 17；
- 使用 Swift、SwiftUI、SwiftData，以及必要的 UIKit／ImageIO 系统能力；
- 免费、无广告，不收集行为分析数据；
- 用户的原始目录始终只读；
- 漫画图片保存在当前设备，不通过 iCloud 同步；
- 核心导入与阅读功能不依赖网络或 iCloud；
- 不支持 iPhone、Mac Catalyst、在线漫画源或 App Store 发布流程。

## 开发路线

| 里程碑 | 目标 | 当前状态 |
|---|---|---|
| M0 | 仓库、Xcode 工程、测试与 CI 基线 | 已完成 |
| M1.1 | 领域模型、目录识别、格式探测与导入清单 | 已完成 |
| M1.2 | 导入预览与可恢复复制 | 已完成 |
| M1.3 | 基础书库 | 已完成 |
| M1.4 | 3 种阅读模式 | 已完成 |
| M2 | 增量更新、完整本地管理与完整 iPad 体验 | 进行中 |
| M3 | iCloud 元数据同步、性能硬化与公开发布工程 | 待开始 |

里程碑状态以仓库中的代码、测试和 CI 结果为准。

## 本地开发

开发需要：

- macOS；
- 支持 iPadOS 17 SDK 的 Xcode；
- XcodeGen 2.45.4；
- iPad Simulator，或由开发者自行配置签名的 iPad。

`project.yml` 是 Xcode 工程的唯一事实来源，生成的 `ComicReader.xcodeproj` 不提交。克隆仓库后运行：

```bash
xcodegen generate
open ComicReader.xcodeproj
```

然后运行 `ComicReader` 或 `ComicReader-CI` Scheme。项目采用无签名 Simulator 构建作为基础验证路径；具体命令和固定 Xcode 版本以 GitHub Actions 配置为准。

## GitHub Actions 构建

当前 CI 行为如下：

- Pull Request：编译、测试和静态检查，不保留 IPA；
- `main`：生成短期的未签名 IPA、dSYM 和构建信息 Artifact；
- `v*` Tag：生成版本化未签名产物并附加到 GitHub Release。

可在 [GitHub Actions](https://github.com/LouisLu010/ComicReader/actions) 下载最近一次 `main` 构建产物。短期 Artifact 默认保留 7 天。

仓库与 CI 不存放证书、私钥、Provisioning Profile 或签名密码，也不负责安装。未签名 IPA 需由使用者在仓库之外自行签名。

### 下载与校验未签名产物

请登录 GitHub，打开状态为成功的 `Main Unsigned Artifact` 运行，并在页面底部的 `Artifacts` 区域下载 `comicreader-main-unsigned-<完整 SHA>`。不要下载源码 ZIP 或日志压缩包。

浏览器下载的是 GitHub 生成的外层 Artifact ZIP。解压一次后会得到：

- `ComicReader-main-<短 SHA>-unsigned.ipa`；
- `ComicReader-main-<短 SHA>.dSYM.zip`；
- `ComicReader-main-<短 SHA>-build-info.txt`；
- `ComicReader-main-<短 SHA>-SHA256SUMS.txt`。

`.ipa` 本身也是 ZIP 容器，但自行签名时应直接把它交给签名工具，无需手动再次解压。Workflow 中的 `compression-level: 0` 仅关闭数据压缩以加快上传，仍会生成合法的 Artifact ZIP。

推荐使用 GitHub CLI 下载。该命令会自动解开外层 Artifact ZIP：

```powershell
gh auth login

$runId = gh run list `
  -R LouisLu010/ComicReader `
  --workflow main.yml `
  --status success `
  --limit 1 `
  --json databaseId `
  --jq '.[0].databaseId'

gh run download $runId `
  -R LouisLu010/ComicReader `
  --pattern 'comicreader-main-unsigned-*' `
  --dir .\ComicReaderArtifact
```

使用 `--pattern` 时，GitHub CLI 可能在目标目录下再创建一个以 Artifact 命名的子目录，这是正常行为。若命令返回 HTTP `410 Gone` 或找不到匹配的 Artifact，说明该短期产物已经过期且无法恢复；请重新触发一次 `main` Workflow，或从 `v*` Tag 对应的 GitHub Release 下载长期保留的 IPA。

下载后可核对产物 Hash：

```powershell
$checksum = Get-ChildItem .\ComicReaderArtifact -Recurse -File -Filter '*-SHA256SUMS.txt' | Select-Object -First 1
$ipa = Get-ChildItem .\ComicReaderArtifact -Recurse -File -Filter '*-unsigned.ipa' | Select-Object -First 1
$dsym = Get-ChildItem .\ComicReaderArtifact -Recurse -File -Filter '*.dSYM.zip' | Select-Object -First 1

Get-Content -LiteralPath $checksum.FullName
Get-FileHash -Algorithm SHA256 -LiteralPath $ipa.FullName
Get-FileHash -Algorithm SHA256 -LiteralPath $dsym.FullName
```

如果浏览器下载的 `.zip` 仍无法解压，先检查文件是否下载完整，以及文件头是否为 ZIP 的 `50 4B`：

```powershell
Format-Hex .\artifact.zip | Select-Object -First 1
Expand-Archive -LiteralPath .\artifact.zip -DestinationPath .\ComicReaderArtifact
```

若文件很小，或文件内容以 HTML、JSON 开头，通常是未登录时保存了登录页／错误响应，或下载了尚未成功运行的页面内容，需要从成功运行底部的 `Artifacts` 区域重新下载。

## 隐私与内容安全

请勿向仓库、Issue、日志或 CI Artifact 提交：

- 真实商业漫画、用户导入的图片或私人测试书库；
- Apple 签名证书、私钥、Provisioning Profile 或相关密码；
- 包含用户漫画名称、绝对路径或图片内容的诊断数据；
- API Token、账号凭据或其他 Secret。

测试素材必须自行生成、原创，或具有明确且兼容的再分发许可。

## 参与贡献

提交改动前，请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。第三方依赖及许可证记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## License

本项目使用 [MIT License](LICENSE)。
