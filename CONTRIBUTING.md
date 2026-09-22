# Contributing / 贡献指南

Thanks for helping improve Timepane. Please keep changes focused, preserve the
corner-first interaction model, and avoid adding permanent Dock or menu-bar UI.

1. Fork the repository and create a focused branch.
2. Generate the project with `xcodegen generate`.
3. Select your own development team in Xcode if signing requires it.
4. Add or update tests for behavior changes and run the full test suite.
5. Describe the visible result, validation, and any remaining limitation in the
   pull request.

For animation or layout changes, include a screenshot or short recording made with
demo data. Never upload a capture containing a real calendar, private event title,
meeting link, location, or notes.

---

感谢你帮助改进 Timepane。请保持改动聚焦，延续“屏幕角落优先”的交互方式，不要添加
常驻 Dock 或菜单栏的界面。

1. Fork 仓库并创建职责单一的分支。
2. 使用 `xcodegen generate` 生成工程。
3. 如果签名提示需要 Team，请在 Xcode 中选择自己的开发者团队。
4. 行为变更需补充或更新测试，并运行完整测试套件。
5. 在 Pull Request 中说明可见结果、验证方式和尚存限制。

涉及动画或布局时，请使用演示数据提供截图或短录屏。不要上传包含真实日历、私密事件
标题、会议链接、地点或备注的素材。
