# 参与贡献

感谢你帮助改进 ComicReader。项目仍处于分阶段开发期，请先阅读 [PRD](docs/PRD.md) 和 [实施计划](docs/IMPLEMENTATION_PLAN.md)，确认改动与当前里程碑一致。

## 开始之前

1. 搜索现有 Issue 和 Pull Request，避免重复工作。
2. 对行为变化、数据模型变化或较大功能，先创建 Issue 说明目标、范围和验收方式。
3. 保持改动小而聚焦，不在同一个 Pull Request 中混入无关重构。
4. 不修改用户原始漫画目录；文件导入相关测试必须使用临时目录或可控替身。

## 开发与验证

- 仅面向 iPad，最低支持 iPadOS 17；
- 遵循现有 Swift、SwiftUI 和测试命名方式；
- 公共函数需要测试，并覆盖边界和错误路径；
- 核心模块覆盖率目标不低于 80%；
- 文件 I/O、哈希和完整图片解码不得阻塞 MainActor；
- 新增 UI 需要检查 VoiceOver、Dynamic Type、本地化和降低动态效果；
- 提交前运行受影响的 Unit Tests、UI Tests、性能测试及无签名构建；
- `Package.resolved` 应随依赖变更一并提交，确保构建可复现。

如果本地环境无法运行某项检查，请在 Pull Request 中明确说明未验证内容及原因。

## Commit 与 Pull Request

Commit 信息使用简体中文，格式为：

```text
类型: 简短描述
```

可用类型包括 `feat`、`fix`、`refactor`、`docs`、`test` 和 `chore`。

Pull Request 应包含：

- 解决的问题与用户可观察变化；
- 关键实现取舍；
- 已执行的测试及结果；
- UI 改动的截图或录屏；
- 数据迁移、隐私、无障碍和性能影响；
- 关联的 Issue。

## 第三方依赖

优先使用 Apple 系统框架。新增 Swift Package 或构建工具时必须：

- 说明系统能力为何不足；
- 固定明确版本并提交锁定文件；
- 确认许可证与 MIT 项目兼容；
- 确认不包含广告、追踪或隐式联网行为；
- 更新 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；
- 为外部依赖提供可控替身，避免测试访问真实服务。

## 禁止提交的内容

不得提交：

- 真实商业漫画、用户导入内容或来源不明的图片；
- Apple 证书、私钥、Provisioning Profile、签名密码或已签名 IPA；
- API Token、账号凭据、`.env` 私密配置或其他 Secret；
- 含用户漫画名称、绝对路径、图片内容或私人设备信息的日志；
- Xcode 用户状态、DerivedData、构建产物或本地缓存。

测试媒体必须自行生成、原创，或具有明确且兼容的再分发许可。发现凭据或敏感内容时，请不要创建公开 Issue，改按 [SECURITY.md](SECURITY.md) 报告。

## 行为准则

请保持讨论友善、具体并聚焦技术事实。尊重不同经验背景，对评审意见给出可复现证据，避免人身攻击、骚扰或歧视。
