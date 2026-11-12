# 更新记录

## [v0.12.0-beta.1] — 2026-11-13

首次面向公众的 **Beta 预发布**，基于此前通过专用 StorageProbe 真机验证与 macOS CI 回归的 RC 候选代码。

### 当前能力

- 支持 Application Support、WebKit、Cookies 的受控目录重定位，以及部分 NSUserDefaults / CFPreferences 实时偏好数据持久化。
- 支持自建 Library 目录的保守识别与备份，ZIP v1/v2/v3 导入及冷启动事务恢复。
- 导入时核对备份来源应用标识，检测 Preferences 写入完整性风险，并避免在目录冲突时自动覆盖原数据。
- 首次引导、文件 App 访问、Inbox ZIP 导入、恢复记录与独立测试工具。

### 本次发布整理

- 重写面向使用者的 README；将技术架构、集成细节、恢复指南、测试证据和安全约束整理至独立文档。
- 将 RC 验收记录转为公开 Beta 的已知限制与后续验证清单。
- 将自动化构建与测试流程的展示名称调整为 Beta 验证。

### 重要限制

- 仅对 StorageProbe 覆盖的场景具备已记录的 iOS 真机跨安装验证；真实第三方 App、不同签名身份和异常磁盘环境仍需更多测试。
- 不支持 Keychain、App Groups、全量 Caches/tmp、任意系统偏好域或服务器登录态的完整迁移。
- **必须在删除 App 之前，将完整 ZIP 独立保存到该 App 沙盒之外。**
- Release 二进制为 **未签名** dylib；测试 IPA 也未签名，且不自带 dylib。使用前需自行注入、签名和安装。

[完整 Beta 验收状态](docs/BETA-STATUS.md) · [安装与恢复](docs/BACKUP-RESTORE.md) · [安全说明](docs/SAFETY.md)
