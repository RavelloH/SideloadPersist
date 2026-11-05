# SideloadPersist — iOS 数据持久化 dylib（实验性）

**v0.9 开发版：目录级持久化 + Apple 风格首次介绍页 / 恢复完成页 + 扩展存储范围诊断。** 主存储仍不依赖外部文件夹选择器，也不依赖证书的 Bundle ID 与 `application-identifier` 匹配。

## 运行机制

插件在 dyld 启动加载时，首先同步执行文件系统初始化，尽量阻止 App 主程序在迁移期间运行（但不保证阻止此前系统框架启动的文件访问）。仅对 `Library/Application Support` 执行同卷 `rename()`，然后建立符号链接：

```text
App 沙盒/
├─ Documents/
│  └─ SideloadPersist/
│     ├─ Data/
│     │  └─ Application Support/       ← 真实、唯一的数据源
│     ├─ Inbox/                        ← 手动复制 ZIP 后可扫描
│     ├─ Incoming/                     ← ZIP 恢复暂存
│     ├─ Backups/                      ← 恢复前的数据，不自动清理
│     └─ manifest.json
└─ Library/
   └─ Application Support → Documents/SideloadPersist/Data/Application Support
```

原始路径可继续通过 Foundation、POSIX、SQLite、CoreData 等 API 访问，具体兼容性须用真机测试。源目录与目标目录都含有数据时，停止重定位，不自动合并/覆盖。迁移出错也不得删除原数据。

**当前不会重定位**：`Library/Preferences`、`Library/Caches`、`Library/WebKit`、`tmp`、Keychain、App Groups。不能将这版当作“所有 App 数据已经备份”。

## 首次介绍页

完成同步初始化后，等 App 存在一个有效前台 Scene，以 **仅一个自定义高度 detent 的 Sheet** 展示一次介绍页（iOS 16+ 约为可用高度的 84%，高度至少按 640pt 申请并由系统上限裁剪）；不允许向上扩大。iOS 15 回退为单一 large detent。为避免介绍内容被截断，介绍页已去掉内层 UIScrollView，使标题、路径和按钮同时可见。包含大标题、SF Symbols 图标、功能介绍、文件目录、项目仓库及作者入口、独立六步恢复指南（正常使用、签名过期、重新安装、恢复备份、大功告成、更多可能）和备份 ZIP 导入。用户点击开始使用或向下关闭后，后续通常不再展示，也不驻留悬浮按钮或轮询监听。首次提示标记升级为 v3，使已体验旧版的测试 App 能重新看到新版 UI。如果已经完成介绍的 App 后续在 `SideloadPersist/Inbox` 出现 ZIP，插件会在下一次前台激活时重新展示导入入口；成功暂存后将这个 ZIP 移入 `Inbox/Imported/` 保留，以避免每次启动反复提示。

成功导入 ZIP 后，界面先尝试从半屏过渡至 large detent，再进入不可手势关闭的全屏完成页面，显示绿色成功图标与「退出 App」按钮，防止在下次冷启动应用恢复前继续操作。**按钮由用户主动触发 `exit(0)`，iOS 不提供公开的自行重启 API，因此用户仍需手动再次打开 App。** 这种主动退出可能被系统视为不正常退出；在正式版中应评估更自然的 UX。恢复包在退出前已被完整校验并持久暂存。

如果存在尚未执行的 `restore-pending.txt`，即使之前关闭过介绍页，下一次显示时也会进入不可跳过的完成状态。这种 UI 限制只能阻止用户交互，不能完全暂停第三方 App 所有后台线程。

「打开文件 App」尝试 `shareddocuments://`（非 Apple 公开 API，可能失效），失效时显示手动导航路径。文件夹在「文件」中的可见性依赖**签名后的 App Info.plist**：

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

签名工具可以提供「开启文件访问」开关；dylib 自己不能在运行时为系统注册文件提供器。

## 手动恢复

1. **原 App 仍安装时**，在「文件」App 中找到「在我的 iPhone > 原 App > SideloadPersist」，将其完整复制到其他位置（包括 `Data`）。签名过期但尚未删除时，在目前实测环境中仍可读取 Documents。
2. 删除原 App、重新签名安装后，先启动一次，让插件建立目录，再返回「文件」App。注意**删除 App 会删除 App 自己的 Documents**。
3. 可先在「文件」App 复制备份中的 `Data/Application Support` 到新 App 的同名目标位置，再重新启动，或者使用首次介绍页的「导入备份 ZIP」按钮。

ZIP 导入支持通过系统选择器“导入副本”，以及将唯一 ZIP 放进 `SideloadPersist/Inbox/` 再点「扫描 Inbox 中的 ZIP」。由「文件」App/Finder 创建的 ZIP 往往包含 `__MACOSX/`、`._*`、`.DS_Store` 辅助元数据；导入器会跳过这些无关条目，不污染 `Application Support`。若签名身份不匹配导致系统选择器失效，仍能使用 Inbox。

可导入 ZIP 的内容布局：

- `SideloadPersist/Data/Application Support/...`
- `Data/Application Support/...`
- `Library/Application Support/...`
- `Application Support/...`
- 单层包装目录或直接包含 Application Support 的内容

**导入不会即时覆盖正在运行的数据库。** ZIP 先做路径、安全类型、大小校验并解压到 `Incoming/UUID`；提交待恢复标记，完全退出并冷启动后才将旧目标文件夹移动到 `Backups/UUID`，再安装新目标。若中断，会尝试修复或保留原目录。当前仅导入 Application Support；不自动迁移 Preferences/Keychain。

不要在 App 活跃写入 SQLite WAL 时压缩文件。恢复时仍需验证数据库完整性。导出到公开的 Documents 也可能暴露敏感账号数据，请谨慎保管。

## 测试项目

GitHub Actions 自动生成（未签名）：

- `SideloadPersist-ios-arm64-unsigned`：注入式 dylib；
- `StorageProbe-unsigned-ipa`：测试 `NSFileManager`、`NSData`、`NSFileHandle`、POSIX `open/write/stat`、`stdio`、SQLite WAL、CoreData SQLite、NSUserDefaults；另加 **WebKit / Preferences 存储范围研究**按钮，枚举部分 Library 子目录是否存在、尝试 WKWebView `localStorage` 持久化。扩展测试不会搬移这些系统目录，避免未经验证直接破坏 WebKit 或 cfprefsd。增强的 StorageProbe 将分别输出 `PREFERENCES_COUNTER`、`WEBKIT_LOCALSTORAGE`、`WEBKIT_INDEXEDDB`、`WEBKIT_COOKIE_COUNTER` 和 `WEBKIT_DATA_RECORDS`，并比较 `Library/WebKit`、`Library/Cookies`、`Library/Caches/com.apple.WebKit.Networking`、`Library/Preferences` 的文件数及大小（`SCOPE_FOOTPRINT phase=before/after`）。不输出用户文件名或网站域名。通过二次启动比较各类别是否持续增长，以确定后续真正需要纳入 ZIP 恢复的目录。目录大小统计只是时点采样；WebKit 网络进程可能异步刷新，不能直接用文件大小证明数据确实只保存在某个目录。
- `PickerProbe-unsigned-ipa`：保留的文件选择器兼容性测试。

**StorageProbe 不自带 dylib。** 使用 LCSign 等工具注入 dylib、开启文件共享、签名安装，打开 StorageProbe 后按「运行存储 API 测试」，复制结果并在「文件」App 中确认 `SideloadPersist/Data/Application Support/StorageProbe` 下确实存在文件。新版输出 `SQLITE_ROWS`、`COREDATA_ROWS` 精确计数，以及 `PERSISTENT_DATA_MARKER`（随 Documents 数据恢复）和 `INSTALLATION_ID`（属于 UserDefaults，卸载重装后变化）。严格验证跨安装恢复时：备份前记录这些数值；重装后导入 ZIP、冷启动再运行，应该看到安装 ID 改变、数据标记恢复到旧值、两种数据库的记录数从旧值继续增加。不要直接在重要 App 上测试首次目录迁移。

CI 另在 macOS 隔离 HOME 环境中验证原子迁移、符号链接路径读写、恶意 ZIP 穿越拦截、ZIP 暂存以及重新启动恢复；**这些并非 iOS 27.0.1 的真机测试**。

本地 macOS/Xcode 编译：`make all`。

## 源码结构与许可

- 新架构：`PDEntry.m`、`PDStorage.m`、`PDIntro.m`、`PDArchive.m`。
- `PDGate.m`、`PDHooks.m`、`PDRedirect.m` 等为早期技术参考，**不参与当前编译**。
- 项目 MIT；`vendor/miniz` 保留原 MIT 许可；历史 fishhook 亦保留原许可证。

本项目不会包含任何用户证书、私钥，不自动发布 Release。
