# 构建、验证与测试证据

本页区分 macOS 自动化模拟测试与 iOS 真机跨安装测试；两者不能互相替代。

## 测试项目

GitHub Actions 自动生成（未签名）：

- `SideloadPersist-ios-arm64-unsigned`：注入式 dylib；
- `StorageProbe-unsigned-ipa`：用于 Foundation、POSIX、SQLite、CoreData 及 WebKit/Preferences/Cookies 测试。`WebKit`、`Cookies` 与 `Application Support` 自动重定位；`Preferences` 改由 live API Hook 覆盖部分 NSUserDefaults/CFPreferences 入口；测试 IPA 不再提供专门的实验开关。对于来源/目标冲突的路径，插件会停止迁移而非自动覆盖。

增强的 StorageProbe 将分别输出 `PREFERENCES_COUNTER`、`WEBKIT_LOCALSTORAGE`、`WEBKIT_INDEXEDDB`、`WEBKIT_COOKIE_COUNTER` 和 `WEBKIT_DATA_RECORDS`，并比较 `Library/WebKit`、`Library/Cookies`、`Library/Caches/com.apple.WebKit.Networking`、`Library/Preferences` 的文件数及大小（`SCOPE_FOOTPRINT phase=before/after`）。不输出用户文件名或网站域名。通过二次启动比较各类别是否持续增长，以确定后续真正需要纳入 ZIP 恢复的目录。目录大小统计只是时点采样；WebKit 网络进程可能异步刷新，不能直接用文件大小证明数据确实只保存在某个目录。
- `PickerProbe-unsigned-ipa`：保留的文件选择器兼容性测试。

**StorageProbe 不自带 dylib。** 使用 LCSign 等工具注入 dylib、开启文件共享、签名安装，打开 StorageProbe 后按「运行存储 API 测试」，复制结果并在「文件」App 中确认 `SideloadPersist/Data/Application Support/StorageProbe` 下确实存在文件。新版输出 `SQLITE_ROWS`、`COREDATA_ROWS` 精确计数，以及 `PERSISTENT_DATA_MARKER`（随 Documents 数据恢复）和 `INSTALLATION_ID`（存于未重定位的 Caches，卸载重装后变化）。严格验证跨安装恢复时：备份前记录这些数值；重装后导入 ZIP、冷启动再运行，应该看到安装 ID 改变、数据标记恢复到旧值、两种数据库的记录数从旧值继续增加。不要直接在重要 App 上测试首次目录迁移。

CI 另在 macOS 隔离 HOME 环境中验证原子迁移、符号链接路径读写、恶意 ZIP 穿越拦截、ZIP 暂存以及重新启动恢复；**这些并非 iOS 27.0.1 的真机测试**。

本地 macOS/Xcode 编译：`make all`。

## 一键全量 StorageProbe 验收（推荐，节省实机重装次数）

新版 StorageProbe 顶部新增 **「一键综合测试 · 备份前 / 恢复后」**。测试不依赖更多证书、后台服务或单独的文件选择器操作。**只需备份前、重新安装并恢复后各点击一次同一个按钮**，不要额外依次运行旧测试按钮，否则那些操作会改变数据库/WebKit 的计数，影响与基线的精确比对。

1. **旧安装（备份前）**：先确保已经注入 dylib；点击一次综合测试，等待日志中出现 `FULL_CYCLE_SUMMARY` 与 `BACKUP_BASELINE_READY`。它会将 `fullcycle-baseline.json` 和 1 MiB 可校验二进制样本等写入可迁移的 `Data/Application Support/StorageProbe`。检查 `fail=0` 后，完整退出 App，使用「文件」App 将整个 `SideloadPersist` 压缩成 ZIP 并保存到此 App 目录之外。
2. **删除并重新安装**：确认 ZIP 在其他位置且文件可读取，再删除测试 App 并重新签名安装，注入相同插件。打开 App 一次完成三目录初始化，通过「导入备份 ZIP」导入完整备份；待提示暂存完成后关闭 App 并再次打开。
3. **恢复后**：再次点击相同的综合测试按钮，程序会自动识别 `installationID` 与基线记录不同，切换到 `RESTORED_INSTALLATION_VERIFY`，对已重定位的数据执行**恢复前值精确比较**，而不仅仅检查 API 是否成功。完成后显示 `FULL_CYCLE_SUMMARY`、`RESTORE_TEST_FINISHED`，同时生成 `SideloadPersist/fullcycle-verification.json`。

一次执行覆盖：Application Support / WebKit / Cookies 符号链接和 Preferences API Hook；Foundation 原子写入；1 MiB 文件及 SHA-256 校验；POSIX、mmap、fsync；NSFileCoordinator；SQLite WAL/事务/完整性；CoreData SQLite；WebKit localStorage、IndexedDB、持久化 Cookie；NSUserDefaults 标准域、Suite、CFPreferences 同步；Keychain 测试用通用密码（仅自建测试项，不读取实际密码）；Library/Caches；可配置 App Group 容器（没有 entitlement 时明确跳过）。同时检查 v2 存储清单和恢复收据。

测试将结果区分为 `PASS`、`FAIL`、`SKIP` 和 `OBS NATIVE_NOT_IN_ZIP`：Keychain、Caches 与 App Groups 目前**不在 SideloadPersist 备份范围中**，因此即使其原生状态跨安装保存，也不应算作插件恢复成功。`SKIP` 代表未获得相应权限或未配置；不是应用故障。Keychain 的持久行为还受 Team ID、Keychain access groups 等签名条件约束。当前测试用 App Group 可通过构建时的可选 `StorageProbeTestAppGroup` Info.plist 字段传入，使用前需确保匹配的签名 entitlement。

基线存在但某项失败时，会保存标记为 `complete=false` 的部分结果，并在日志中显式警告；不要用它证明失败项目成功恢复。测试完成并输出 `BACKUP_BASELINE_READY` **之前不要开始压缩**；WebKit 数据写盘可能异步，压缩前仍必须彻底退出 App。旧版 StorageProbe 的单项按钮保留用于故障定位。

本次综合测试继续增加：`fopen`/`fputs`/`fflush`、`NSFileHandle`、`NSFileManager` 拷贝与移动、中文与 Emoji 文件名、`NSDataReadingMappedIfSafe`、CFPreferences 独立同步、合成 `NSURLCache` 响应、`NSTemporaryDirectory()`。这些测试不需要联网，不访问实际应用凭据或个人内容。已有的文件/数据库/WebKit 恢复断言不会因添加新探针而放松。`fullcycle-baseline.json` 会标明 `complete`，如遇 FAIL，后续恢复验证将提示基线不完整而不会误判为成功。

### StorageProbe v2 实机跨安装验收步骤

1. **备份测试数据**：运行 StorageProbe 的存储 API 与 WebKit 诊断，记录 `WEBKIT_LOCALSTORAGE`、`WEBKIT_INDEXEDDB`、`WEBKIT_COOKIE_COUNTER` 的 `after` 值，确认两个 `EXPERIMENT_LINK`（历史日志字段）均为 `yes`。完全结束 App，将 `SideloadPersist` 压缩并保存到 App 文件夹之外。
2. **重新安装**：确认 ZIP 已安全保存，删除并重新安装测试 IPA，注入当前 dylib。首次启动即自动重定位四个目录，无需再次启用或冷启动实验模式。确认 WebKit/Cookies 符号链接存在。
3. 在「文件」App 中把备份 ZIP 放到新 StorageProbe 的 `SideloadPersist/Inbox`（或使用可用的系统文件选择器），启动导入，完成校验后按提示结束进程，重新打开 App。
4. 点击「研究 WebKit / Preferences 存储范围」，确认 `RESTORE_V2_LAST result=committed scopes=(Application Support, WebKit, Cookies)`，并且三个 WebKit 存储计数的 `before` 值与备份前的 `after` 值对应，再观察它们递增。`PERSISTENCE_MANIFEST` 应为 `SideloadPersist.Directory.V2`。

v2/v3 成功恢复后生成 `SideloadPersist/restore-last.json` 收据，记录恢复事务 ID、涉及目录及时间；旧数据保持在 `Backups/<id>/Data`，不自动清理。**三目录 v2 及 Preferences v3 已通过 StorageProbe 在 iOS 27 真机跨安装验收**；macOS CI 的模拟文件测试不能保证 WebKit 进程对于重新安装环境的数据接受度。备份时应让 App 和 WebKit 相关进程结束，以避免压缩正在写入的数据库。Keychain 不包含在此恢复方案中。
