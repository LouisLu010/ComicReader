<spec-entry category="quality" keywords="M2.3,iPad,privacy,accessibility,display" date="2026-09-06" source="docs/IMPLEMENTATION_PLAN.md;ComicReaderTests/PrivacyLockCoordinatorTests.swift;ComicReaderUITests/IPadExperienceUITests.swift">

# M2.3 验收范围

## 已接入功能及自动化

- 多窗口：`ComicWindowRequest` 为每次打开生成独立身份，系统可序列化恢复。UI 测试打开独立漫画窗口；既有 ReaderSession 测试负责会话和进度合并语义。
- 隐私：系统 `.deviceOwnerAuthentication`，冷启动锁定，窗口失活遮罩覆盖所有弹窗；最后活跃窗口进入后台后锁定。单元测试覆盖失败、取消、开关认证、多窗口、迟到认证结果；UI 夹具覆盖冷启动解锁、打开编辑弹窗后切后台重锁。
- 展示：背景、内容亮度、白边裁切、旋转、常亮、动画均接入真实阅读视图。白边探测最多使用 256 像素预览，CPU 处理离开主线程；原图与原始缓存不变。单元测试覆盖空白页、裁切、旋转、持久化、范围归一化和多窗口常亮租约。
- 辅助功能：新交互均提供标签及稳定标识，文案有简体中文／英文；详情适应紧凑窗口和辅助字号；最大字号 UI 测试确保阅读入口和翻页操作可用；高对比度提供实色控件底色，系统 Reduce Motion 强制关闭自定义动画。

CI 会运行完整测试并打包未签名 IPA。具体通过与否以对应提交的 GitHub Actions 结果为准。

## 尚需真机验收（不能由 Windows／Simulator 代替）

- 用户自行签名安装到 iPad，验证 Face ID／Touch ID 成功、失败、取消、设备密码回退及设备未设置密码时的行为。
- 在阅读、章节列表和元数据编辑弹窗中触发多任务预览，检查预览中无漫画页面、封面或文件名；冷启动前也不应闪现内容。
- 在支持 Stage Manager 的 iPad 上并排打开两个阅读窗口，调整大小、横竖屏、关闭其中一个窗口，确认另一窗口导航与常亮不受影响。
- 连接外接显示器，移动窗口、改变分辨率、拔插显示器，确认内容布局与点击区域跟随所属窗口，未发生跨屏数据泄露。
- 使用 VoiceOver 和外接键盘／触控板完成导入、打开、翻页、缩放、设置和解锁；检查最大字号、高对比度、降低透明度／动态效果与中英文界面。

这些项目尚未实测，因此不能声称 M2.3 已完成真机验收，也不能将 M2.1／M2.2 未完成项目算入已完成的 M2。

## 平台参考

- [Apple：设备所有者认证](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)
- [Apple：WindowGroup](https://developer.apple.com/documentation/swiftui/windowgroup)
- [Apple：openWindow](https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow)

</spec-entry>
