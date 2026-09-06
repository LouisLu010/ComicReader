# 项目验收规则

<spec-entry category="quality" keywords="milestone,prd,acceptance,traceability" date="2026-09-06" source="docs/PRD.md:88;docs/IMPLEMENTATION_PLAN.md:318;0201432">

## 里程碑必须逐条对照 PRD

完成或验收里程碑前，必须逐条对照 `docs/PRD.md` 中归属该里程碑的用户故事与约束，并与 `docs/IMPLEMENTATION_PLAN.md` 的摘要交叉检查，不能仅凭实施计划摘要宣称完成。

为每项要求明确实现位置、自动化验证证据及尚需人工或真机验证的部分。例如 M2.3 的旋转要求包含“单页独立旋转”，留白裁切包含“纯色留白”，不能分别以统一旋转或仅白边裁切替代。CI 通过不等于 Face ID、Stage Manager 或外接显示器已经完成真机验收。

</spec-entry>
