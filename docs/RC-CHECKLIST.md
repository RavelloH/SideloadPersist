# SideloadPersist · RC 候选验收清单

> 状态：Release Candidate 候选代码评审与验证中。尚未发布 GitHub Release；不保证所有第三方应用均能无损恢复。

## 已证明的核心能力

- StorageProbe 已通过 iOS 真机卸载重装后 Application Support、WebKit、Cookies、Preferences 的数据接续（v3）；含 SQLite/WAL、CoreData、localStorage、IndexedDB、Cookie、标准 UserDefaults、普通 Suite、CFPreferences。
- App 自建 Library 顶层目录能从现有 Application Support 备份范围恢复，且不影响 SplashBoard / Caches 等系统目录。
- CI 覆盖 ZIP 路径安全、旧版 ZIP 兼容、事务回滚、中断重放和系统偏好域隔离。
- 用户备份路径：`Documents/SideloadPersist/`。普通 Documents 文件无需插件迁移，且不自动打包到 SideloadPersist ZIP。

## RC 本轮安全改动

- ZIP 源应用身份检查：相同 Bundle ID 自动允许暂存；身份不同或旧包缺失标识时必须由用户主动确认。不是密码学鉴权，更换 Team ID 也不意味着 Keychain 可以迁移。
- Preferences Hook 任一托管写入失败时，自动记录 `preferences-integrity-warning.json`，并在 App 中显示一次风险提示；StorageProbe 禁止生成有效备份基线；具有错误标记的 ZIP 不能恢复，即使用户批准身份异常。
- 修复参数偏好域与已注册默认值的优先级，以及删除键在 `dictionaryRepresentation` 中的表现。
- 更新引导与恢复提示，避免“永远不会丢数据”“暂存即恢复成功”等绝对化文案。
- 增加 macOS CI 故障注入、ZIP 身份拒绝/确认、400 次并发偏好写入测试。

## RC 验收尚未完成（需要真机）

- [ ] 一款原生业务 App：首次注入、日常使用、独立 ZIP、完全卸载、同 Bundle ID 恢复
- [ ] 一款 WebView / 混合 App：WebKit、登录状态及 Preferences 的真实行为
- [ ] 一款跨平台 App：自建 Library 目录、数据库、资源目录
- [ ] 更换真实签名 Team ID 的恢复试验，记录哪些 Keychain / App Group 数据无法跨身份恢复
- [ ] 受限存储容量或模拟写入故障后的用户可见警报与禁止备份提示
- [ ] 用户确认来源身份不一致与旧版 ZIP 的安全提示在 iOS 上正常显示
- [ ] iOS 真机高频更新与并发场景，观察异常 I/O、内存、UI 卡顿及电池影响

## 当前明确不支持的范围

Keychain、App Groups、全部 Caches、tmp、系统保留的 Library 目录、普通 Documents 文件的自动打包、未被公开 API Hook 覆盖的系统偏好域。不应因 StorageProbe 通过就承诺任意 App 登录状态、签名身份或服务器账户均可恢复。

## 发布规则

先保留未发布 RC 构建作为内部候选，待 CI 与真实 App 验收完成后再决定是否公开 Beta/RC；未经用户单独确认，不创建 GitHub Release，不自动覆盖已有 Release。
