# SideloadPersist — iOS 数据持久化 dylib（实验性）

**Preferences API Hook 研发版：Application Support / WebKit / Cookies 使用目录重定位；Preferences 使用按域实时写入的 API Hook，支持多目录 ZIP v3，同时兼容 v1/v2。** 当前 Hook 仍待 iOS 27 真机跨安装验证，不应视为对所有系统偏好域的完整支持。不依赖测试 Bundle ID、Info.plist 开关、标记文件，也不依赖系统文件选择器授权。

## 运行机制

插件在 dyld 启动加载时，首先同步执行文件系统初始化，尽量阻止 App 主程序在迁移期间运行（但不保证阻止此前系统框架启动的文件访问）。针对 Application Support、WebKit 与 Cookies 使用同卷 `rename()` 并建立符号链接。Preferences 由 API Hook 直接写入 `Data/Preferences` 的单份偏好域 plist，不移动 `Library/Preferences`：

```text
App 沙盒/
├─ Documents/
│  └─ SideloadPersist/
│     ├─ Data/
│     │  ├─ Application Support/       ← SQLite / CoreData 等真实文件
│     │  ├─ WebKit/                    ← WebKit 数据
│     │  ├─ Cookies/                   ← Cookie 数据
│     │  └─ Preferences/               ← API Hook 实时域文件（非快照）
│     ├─ Inbox/                        ← 手动复制 ZIP 后可扫描
│     ├─ Incoming/                     ← ZIP 恢复暂存
│     ├─ Backups/                      ← 恢复前的数据，不自动清理
│     └─ manifest.json
└─ Library/
   ├─ Application Support → Documents/SideloadPersist/Data/Application Support
   ├─ WebKit → Documents/SideloadPersist/Data/WebKit
   ├─ Cookies → Documents/SideloadPersist/Data/Cookies
   └─ Preferences/                 ← iOS 系统管理目录，原样保留
```

原始路径可继续通过 Foundation、POSIX、SQLite、CoreData 等 API 访问，具体兼容性须用真机测试。源目录与目标目录都含有数据时，停止重定位，不自动合并/覆盖。迁移出错也不得删除原数据。

**目前暂不重定位**：`Library/Caches`、`tmp`、Keychain、App Groups。请勿将目录级备份视为全部 App 数据的完整副本。

## 首次介绍页

完成同步初始化后，等 App 存在一个有效前台 Scene，以 **仅一个自定义高度 detent 的 Sheet** 展示一次介绍页（iOS 16+ 约为可用高度的 84%，高度至少按 640pt 申请并由系统上限裁剪）；不允许向上扩大。iOS 15 回退为单一 large detent。为避免介绍内容被截断，介绍页已去掉内层 UIScrollView，使标题、路径和按钮同时可见。包含大标题、SF Symbols 图标、功能介绍、文件目录、项目仓库及作者入口、独立六步恢复指南（正常使用、签名过期、重新安装、恢复备份、大功告成、更多可能）和备份 ZIP 导入。六步指南使用独立滚动视图，上下边缘通过与系统背景色一致的渐变层柔和隐去内容，暗色模式不再出现灰色光带；「返回」按钮置于固定底部同色背景栏内，始终在安全区域上方，不随正文滚动。用户点击开始使用或向下关闭后，后续通常不再展示，也不驻留悬浮按钮或轮询监听。首次提示标记升级为 v3，使已体验旧版的测试 App 能重新看到新版 UI。如果已经完成介绍的 App 后续在 `SideloadPersist/Inbox` 出现 ZIP，插件会在下一次前台激活时重新展示导入入口；成功暂存后将这个 ZIP 移入 `Inbox/Imported/` 保留，以避免每次启动反复提示。

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

**导入不会即时覆盖正在运行的数据库。** v1 ZIP 继续恢复 Application Support；v2 ZIP 将 Application Support、WebKit、Cookies 作为同一事务暂存并在下一次冷启动恢复。原数据保留在 Backups，发生异常时尝试回滚；新 v3 ZIP 额外支持 Preferences；Keychain 暂未覆盖。

不要在 App 活跃写入 SQLite WAL 时压缩文件。恢复时仍需验证数据库完整性。导出到公开的 Documents 也可能暴露敏感账号数据，请谨慎保管。

## 测试项目

GitHub Actions 自动生成（未签名）：

- `SideloadPersist-ios-arm64-unsigned`：注入式 dylib；
- `StorageProbe-unsigned-ipa`：用于 Foundation、POSIX、SQLite、CoreData 及 WebKit/Preferences/Cookies 测试。`WebKit`、`Cookies` 与 `Application Support` 自动重定位；`Preferences` 改由 live API Hook 覆盖部分 NSUserDefaults/CFPreferences 入口；测试 IPA 不再提供专门的实验开关。对于来源/目标冲突的路径，插件会停止迁移而非自动覆盖。

增强的 StorageProbe 将分别输出 `PREFERENCES_COUNTER`、`WEBKIT_LOCALSTORAGE`、`WEBKIT_INDEXEDDB`、`WEBKIT_COOKIE_COUNTER` 和 `WEBKIT_DATA_RECORDS`，并比较 `Library/WebKit`、`Library/Cookies`、`Library/Caches/com.apple.WebKit.Networking`、`Library/Preferences` 的文件数及大小（`SCOPE_FOOTPRINT phase=before/after`）。不输出用户文件名或网站域名。通过二次启动比较各类别是否持续增长，以确定后续真正需要纳入 ZIP 恢复的目录。目录大小统计只是时点采样；WebKit 网络进程可能异步刷新，不能直接用文件大小证明数据确实只保存在某个目录。
- `PickerProbe-unsigned-ipa`：保留的文件选择器兼容性测试。

**StorageProbe 不自带 dylib。** 使用 LCSign 等工具注入 dylib、开启文件共享、签名安装，打开 StorageProbe 后按「运行存储 API 测试」，复制结果并在「文件」App 中确认 `SideloadPersist/Data/Application Support/StorageProbe` 下确实存在文件。新版输出 `SQLITE_ROWS`、`COREDATA_ROWS` 精确计数，以及 `PERSISTENT_DATA_MARKER`（随 Documents 数据恢复）和 `INSTALLATION_ID`（存于未重定位的 Caches，卸载重装后变化）。严格验证跨安装恢复时：备份前记录这些数值；重装后导入 ZIP、冷启动再运行，应该看到安装 ID 改变、数据标记恢复到旧值、两种数据库的记录数从旧值继续增加。不要直接在重要 App 上测试首次目录迁移。

CI 另在 macOS 隔离 HOME 环境中验证原子迁移、符号链接路径读写、恶意 ZIP 穿越拦截、ZIP 暂存以及重新启动恢复；**这些并非 iOS 27.0.1 的真机测试**。

本地 macOS/Xcode 编译：`make all`。

## 源码结构与许可

- 新架构：`PDEntry.m`、`PDStorage.m`、`PDIntro.m`、`PDArchive.m`。
- `PDGate.m`、`PDHooks.m`、`PDRedirect.m` 等为早期技术参考，**不参与当前编译**。
- 项目 MIT；`vendor/miniz` 保留原 MIT 许可；历史 fishhook 亦保留原许可证。

本项目不会包含任何用户证书、私钥，不自动发布 Release。

## 多目录恢复 v2 / v3（v2 三目录已真机验证；v3 Preferences 尚待验证）

旧版只包含 Application Support 的 ZIP 保持 v1 导入及冷启动恢复流程。备份 ZIP 如果包含 `SideloadPersist/Data/WebKit/` 或 `SideloadPersist/Data/Cookies/`，新的导入器将识别多目录格式；v3 另外包含 Preferences：

```text
SideloadPersist/
├── manifest.json                     （可选的已有状态信息，不直接恢复）
└── Data/
    ├── Application Support/
    ├── WebKit/
    ├── Cookies/
    └── Preferences/           （仅 v3，按域实时 plist，而非系统偏好目录副本）
```

导入前验证每个 ZIP 文件名、Unix 类型和大小；只提取白名单目录到 `Incoming/<id>/Data/`。不处理任意来源的符号链接、绝对路径或 `../`，忽略备份中的 `Inbox`、`Backups` 和 AppleDouble 元数据。预先持久化 `Incoming/<id>/restore-plan.json` 与 `restore-pending.txt`，仅在下次冷启动恢复。原有目录分别移到 `Backups/<id>/Data/`，全部成功才清除 pending。中途失败时保留暂存文件并尽力回滚；意外中断后会根据 target/stage/backup 的状态尝试恢复处理，如存在不确定状态则拒绝覆盖。备份目录永不自动清理。

**v2/v3 的可用范围**：三目录 v2 与四目录 v3 均对所有注入插件的 App 开放。ZIP 路径、目录冲突、事务回滚和清单完整性校验保留。v3 恢复 Preferences 的 API Hook 实时存储文件；`Library/Preferences` 的目录不会被移动。Hook 覆盖标准 NSUserDefaults 常见方法、常规 Suite、应用级 CFPreferences 以及 current-user/any-host 精确域 C 符号，但不涵盖全部底层域 API，iOS 真机兼容性与跨安装恢复仍待验证。Keychain、Caches 等未纳入。

**v2 清单完整性检查**：当 ZIP 内含 `SideloadPersist/manifest.json` 且其 `format=SideloadPersist.Directory.V2` 时，导入器会校验其中 `scopes` 与实际出现的 `Data/*` 目录一致。如果声明包含 Cookies，但 ZIP 丢失该目录，则整体拒绝导入。外部 ZIP 在 `Data/` 下出现尚不支持的目录（例如 Other）时也会明确拒绝，避免只恢复一部分数据。当前只保证 ZIP 提取 CRC 完整性；压缩时如果数据库仍在写入，CRC 正确不意味着 SQLite 事务一致，压缩前应停止 App 活动。

### StorageProbe v2 实机跨安装验收步骤

1. **备份测试数据**：运行 StorageProbe 的存储 API 与 WebKit 诊断，记录 `WEBKIT_LOCALSTORAGE`、`WEBKIT_INDEXEDDB`、`WEBKIT_COOKIE_COUNTER` 的 `after` 值，确认两个 `EXPERIMENT_LINK`（历史日志字段）均为 `yes`。完全结束 App，将 `SideloadPersist` 压缩并保存到 App 文件夹之外。
2. **重新安装**：确认 ZIP 已安全保存，删除并重新安装测试 IPA，注入当前 dylib。首次启动即自动重定位四个目录，无需再次启用或冷启动实验模式。确认 WebKit/Cookies 符号链接存在。
3. 在「文件」App 中把备份 ZIP 放到新 StorageProbe 的 `SideloadPersist/Inbox`（或使用可用的系统文件选择器），启动导入，完成校验后按提示结束进程，重新打开 App。
4. 点击「研究 WebKit / Preferences 存储范围」，确认 `RESTORE_V2_LAST result=committed scopes=(Application Support, WebKit, Cookies)`，并且三个 WebKit 存储计数的 `before` 值与备份前的 `after` 值对应，再观察它们递增。`PERSISTENCE_MANIFEST` 应为 `SideloadPersist.Directory.V2`。

v2/v3 成功恢复后生成 `SideloadPersist/restore-last.json` 收据，记录恢复事务 ID、涉及目录及时间；旧数据保持在 `Backups/<id>/Data`，不自动清理。**三目录 v2 已经通过 iOS 27.0.1 真机跨安装验证，新增 Preferences 的 v3 仍需真机验收**；macOS CI 的模拟文件测试不能保证 WebKit 进程对于重新安装环境的数据接受度。备份时应让 App 和 WebKit 相关进程结束，以避免压缩正在写入的数据库。Keychain 不包含在此恢复方案中。

## 一键全量 StorageProbe 验收（推荐，节省实机重装次数）

新版 StorageProbe 顶部新增 **「一键综合测试 · 备份前 / 恢复后」**。测试不依赖更多证书、后台服务或单独的文件选择器操作。**只需备份前、重新安装并恢复后各点击一次同一个按钮**，不要额外依次运行旧测试按钮，否则那些操作会改变数据库/WebKit 的计数，影响与基线的精确比对。

1. **旧安装（备份前）**：先确保已经注入 dylib；点击一次综合测试，等待日志中出现 `FULL_CYCLE_SUMMARY` 与 `BACKUP_BASELINE_READY`。它会将 `fullcycle-baseline.json` 和 1 MiB 可校验二进制样本等写入可迁移的 `Data/Application Support/StorageProbe`。检查 `fail=0` 后，完整退出 App，使用「文件」App 将整个 `SideloadPersist` 压缩成 ZIP 并保存到此 App 目录之外。
2. **删除并重新安装**：确认 ZIP 在其他位置且文件可读取，再删除测试 App 并重新签名安装，注入相同插件。打开 App 一次完成三目录初始化，通过「导入备份 ZIP」导入完整备份；待提示暂存完成后关闭 App 并再次打开。
3. **恢复后**：再次点击相同的综合测试按钮，程序会自动识别 `installationID` 与基线记录不同，切换到 `RESTORED_INSTALLATION_VERIFY`，对已重定位的数据执行**恢复前值精确比较**，而不仅仅检查 API 是否成功。完成后显示 `FULL_CYCLE_SUMMARY`、`RESTORE_TEST_FINISHED`，同时生成 `SideloadPersist/fullcycle-verification.json`。

一次执行覆盖：Application Support / WebKit / Cookies 符号链接和 Preferences API Hook；Foundation 原子写入；1 MiB 文件及 SHA-256 校验；POSIX、mmap、fsync；NSFileCoordinator；SQLite WAL/事务/完整性；CoreData SQLite；WebKit localStorage、IndexedDB、持久化 Cookie；NSUserDefaults 标准域、Suite、CFPreferences 同步；Keychain 测试用通用密码（仅自建测试项，不读取实际密码）；Library/Caches；可配置 App Group 容器（没有 entitlement 时明确跳过）。同时检查 v2 存储清单和恢复收据。

测试将结果区分为 `PASS`、`FAIL`、`SKIP` 和 `OBS NATIVE_NOT_IN_ZIP`：Keychain、Caches 与 App Groups 目前**不在 SideloadPersist 备份范围中**，因此即使其原生状态跨安装保存，也不应算作插件恢复成功。`SKIP` 代表未获得相应权限或未配置；不是应用故障。Keychain 的持久行为还受 Team ID、Keychain access groups 等签名条件约束。当前测试用 App Group 可通过构建时的可选 `StorageProbeTestAppGroup` Info.plist 字段传入，使用前需确保匹配的签名 entitlement。

基线存在但某项失败时，会保存标记为 `complete=false` 的部分结果，并在日志中显式警告；不要用它证明失败项目成功恢复。测试完成并输出 `BACKUP_BASELINE_READY` **之前不要开始压缩**；WebKit 数据写盘可能异步，压缩前仍必须彻底退出 App。旧版 StorageProbe 的单项按钮保留用于故障定位。

本次综合测试继续增加：`fopen`/`fputs`/`fflush`、`NSFileHandle`、`NSFileManager` 拷贝与移动、中文与 Emoji 文件名、`NSDataReadingMappedIfSafe`、CFPreferences 独立同步、合成 `NSURLCache` 响应、`NSTemporaryDirectory()`。这些测试不需要联网，不访问实际应用凭据或个人内容。已有的文件/数据库/WebKit 恢复断言不会因添加新探针而放松。`fullcycle-baseline.json` 会标明 `complete`，如遇 FAIL，后续恢复验证将提示基线不完整而不会误判为成功。


## 自动生成的 Documents/SideloadPersist/README.md

注入插件完成目录初始化后，将在当前 App 的 `Documents/SideloadPersist/README.md` 自动生成 Markdown 说明，包含：作者 **RavelloH**、[GitHub 项目](https://github.com/RavelloH/SideloadPersist)、当前 App 标识、已建立的各目录映射、Inbox/Incoming/Backups/恢复收据说明、导出/恢复操作及安全提示。它会按照实际符号链接更新内容，而不会将失败的迁移标记为成功。

自动生成的 README 使用 `.readme-generated.sha256` 记录前一次生成文本的哈希；只有上次文件仍保持自动生成内容时，才会在下次启动更新。如果用户手动修改 README（或已有自己的 README），插件会保留内容而不会覆盖。实际映射状态仍以 `manifest.json` 为准。README 处于 Documents 内，删除 App 也会丢失；备份时请将整个 SideloadPersist 文件夹压缩并移到应用目录之外。

## Preferences API Hook 开发实现

iOS 27.0.1 对 `Library/Preferences` 整目录的 `rename()` 返回 `EPERM`。因此不再移动该目录，也不生成周期性快照。改为在 `Documents/SideloadPersist/Data/Preferences/<SHA256(域名)>.plist` 为每个被 Hook 管理的域写入一份 canonical 二进制 Property List；写入和移除操作原子提交，删除键以墓碑记录，防止读取旧原生偏好值。首次初始化可导入原生持久域；这不会自动删除系统存储中已有的数据副本。

Hook 当前涵盖 Foundation `NSUserDefaults` 常见 typed getter/setter、object/remove、`persistentDomain`、普通 Suite；以及 `CFPreferencesCopyAppValue` / `SetAppValue` / `AppSynchronize` 和当前用户、任意主机的 `CopyValue` / `SetValue` / `Synchronize`。测试会检查 `dictionaryRepresentation` 正确隐藏已删除键、直接 CFPreferences 写入能被 NSUserDefaults 读取、跨安装对比 `cfDirect` 计数。App Group Suite、非主域及批量 CFPreferences、进程外 `cfprefsd`、绕过公开 API 的代码路径均不能保证覆盖。v3 ZIP 在导入前校验 Preferences 域文件，冷启动置换保存内容，既有 V2/V1 继续按旧机制恢复。`StorageProbe` 会显示 `PREFERENCES_HOOK_STATUS`、`SCOPE_HOOK Preferences`、`RESTORE_COMPARE userDefaults`、`defaultsSuite`、`cfPreferences`；**目前仅 macOS 模拟测试通过，iOS 真机仍需验收。**
### 后续数据范围优先级

- **可能值得持久化**：Library 下 App 自建的其他非缓存子目录（需先动态枚举和防冲突机制）；进一步验证 NSHTTPCookieStorage/NSURLSession 的真实持久化文件是否完全在 Cookies、WebKit 或其他位置。
- **暂不应直接整体迁移**：Library/Caches、tmp、Saved Application State。这些通常可以重建或受系统自动清理，强行持久化会让数据包膨胀并引入失效状态。
- **不能靠目录符号链接解决**：Keychain、App Groups（还依赖签名 Team ID、entitlement 和系统服务的隔离策略）。
### Preferences 与系统服务

因为 NSUserDefaults / CFPreferences 可能由 `cfprefsd` 异步缓存和写盘，SideloadPersist 在 UIApplication 进入后台、正常终止的通知中请求 `standardUserDefaults synchronize` 和 `CFPreferencesAppSynchronize`，尽力增加备份前 Preferences 内容落盘的机会。但这**不能保证所有 Suite 或系统服务数据立刻一致**，更不能替代「完全退出 App 后再压缩整个文件夹」。请特别留意 v3 真机综合测试中的 `RESTORE_COMPARE userDefaults`、`RESTORE_COMPARE defaultsSuite` 与 `RESTORE_COMPARE cfPreferences`，它们验证的不是目录符号链接而是真实 API 读值。

综合测试 v2 在同一次点击中增加 `LIBRARY_DISCOVERY`（Library 顶层自建目录与未知目录分类）、测试用自建 `Library/StorageProbeCustomPersistent` 和 `NSHTTPCookieStorage` 的持久 Cookie 样本。新增的 `RESEARCH_REINSTALL` 仅用于观察，不计入正式的恢复 PASS/FAIL，以便在同一次跨安装实测里筛选下一批目录，不因为尚未覆盖的数据类别阻断综合基线。

## v0.11.1 修复：扩展目录冲突不再阻断 Application Support

实机发现 v3 原实现会将 WebKit、Cookies、Preferences 三个可选目录视为同一组全有或全无的前置条件：任一目录存在冲突，插件在核心 Application Support 初始化之前就返回。由此产生 `manifest.json` / 自动 README 缺失和所有 symlink 不存在的情况；StorageProbe 虽能直接写入 Documents/Data，但不代表数据真的被原应用路径使用。此问题已通过独立目录迁移修复。

每个可选目录现在独立检查、迁移及回滚；对源和目标都非空的数据严格保持原样，绝不自动覆盖或删除，其他可迁移目录与核心 Application Support 继续运行。对于目标原本是**空文件夹**但源目录有数据的情况，可删除空目标、原子移动原目录，再建立符号链接，失败时尝试恢复原状。对于已有外来符号链接、目录类型不符等情况不操作该目录。

每次启动会创建 `Documents/SideloadPersist/scope-mapping-result.json`，记录各扩展目录的 `mapped`、`reason`、路径类型和直接子项数量（不列出文件名、不读私有文件内容）；同时 `scope-mapping-result.txt` 为 `ready` 或 `partial`。`manifest.json` 和自动 README **只列入真实验证的映射**；如果某个目录没成功映射，README 会明确标注未建立映射。部分扩展目录失效不意味着全部 App 数据都被持久化；在研究阶段应先查清原因再备份。

一键综合测试同时修复了误导性通过信号：没有清单、README、原路径映射，或恢复比较出错时，输出 `BACKUP_NOT_READY` / `BACKUP_ABORTED`，诊断保存在 `fullcycle-diagnostics.json`，**不会**生成新的有效备份基线，也不会再输出 `BACKUP_BASELINE_READY`。只有 `fail=0` 且报告写入成功才允许开始备份。单个数据文件能直接从 Documents 读写不再被用作映射成功的证据。

新增加三类模拟回归：**非空源与非空目标冲突**（继续恢复 Application Support/WebKit/Cookies 并保持 Preferences 双份原样）、**非空源与空目标**（自动迁移、保留数据）、**系统或其他软件创建的外来 Preferences 符号链接**（保留链接，正常启动其他范围）。尚不能从目前的用户日志推断 iOS 27 上冲突的确切底层原因；新版诊断会给出对应 scope 和 reason。

一次性综合测试新增 `PREFERENCES_STORAGE_USAGE` / `PREFERENCES_STORAGE_FINAL`（域文件数量及字节数），用于观察实时偏好后端的实际空间开销；并检查删除键是否同时从 `objectForKey` 与 `dictionaryRepresentation` 消失。也验证 CFPreferences 的精确域 API 与 NSUserDefaults 读取的一致性，不必单独重装第二次。
