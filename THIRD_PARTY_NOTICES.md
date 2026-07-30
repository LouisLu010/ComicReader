# 第三方软件声明

ComicReader 当前没有运行时第三方依赖。项目优先使用 Apple 随平台提供的系统框架；这些系统框架不作为随本仓库再分发的第三方组件列入本文件。

引入新的 Swift Package、源码组件、媒体资源或随产物分发的工具时，贡献者必须在合并前更新本文件，并至少记录：

| 组件 | 固定版本 | 用途 | License | 来源 |
|---|---|---|---|---|
| XcodeGen | 2.45.4 | 从 `project.yml` 生成 Xcode 工程，仅用于开发和 CI | MIT | [yonaskolb/XcodeGen](https://github.com/yonaskolb/XcodeGen) |

测试图片和示例漫画同样需要明确来源与再分发许可。不得使用真实商业漫画或来源不明的素材。

本清单不取代各组件自身的 License 文件；发布产物时必须保留上游许可证要求的完整声明。
