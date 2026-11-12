# 技术原理与实现

本页面向研究者与维护者，说明重定位、偏好 API Hook、备份格式、冲突处理与恢复事务。使用步骤请见 [备份与恢复](BACKUP-RESTORE.md)，安全边界请见 [安全说明](SAFETY.md)。

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

## 多目录恢复 v2 / v3（四个私有数据范围已通过 StorageProbe 真机跨安装验证）

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

**v2/v3 的可用范围**：三目录 v2 与四目录 v3 均对所有注入插件的 App 开放。ZIP 路径、目录冲突、事务回滚和清单完整性校验保留。v3 恢复 Preferences 的 API Hook 实时存储文件；`Library/Preferences` 的目录不会被移动。Hook 覆盖标准 NSUserDefaults 常见方法、常规 Suite、应用级 CFPreferences 以及 current-user/any-host 精确域 C 符号，但不涵盖全部底层域 API，iOS 27 上 StorageProbe 标准域、Suite、应用级与精确域 CFPreferences 均已完成跨安装读值验证，但其他 App 的内部偏好路径仍需逐一确认。Keychain、Caches 等未纳入。

**v2 清单完整性检查**：当 ZIP 内含 `SideloadPersist/manifest.json` 且其 `format=SideloadPersist.Directory.V2` 时，导入器会校验其中 `scopes` 与实际出现的 `Data/*` 目录一致。如果声明包含 Cookies，但 ZIP 丢失该目录，则整体拒绝导入。外部 ZIP 在 `Data/` 下出现尚不支持的目录（例如 Other）时也会明确拒绝，避免只恢复一部分数据。当前只保证 ZIP 提取 CRC 完整性；压缩时如果数据库仍在写入，CRC 正确不意味着 SQLite 事务一致，压缩前应停止 App 活动。

## 自动生成的 Documents/SideloadPersist/README.md

注入插件完成目录初始化后，将在当前 App 的 `Documents/SideloadPersist/README.md` 自动生成 Markdown 说明，包含：作者 **RavelloH**、[GitHub 项目](https://github.com/RavelloH/SideloadPersist)、当前 App 标识、已建立的各目录映射、Inbox/Incoming/Backups/恢复收据说明、导出/恢复操作及安全提示。它会按照实际符号链接更新内容，而不会将失败的迁移标记为成功。

自动生成的 README 使用 `.readme-generated.sha256` 记录前一次生成文本的哈希；只有上次文件仍保持自动生成内容时，才会在下次启动更新。如果用户手动修改 README（或已有自己的 README），插件会保留内容而不会覆盖。实际映射状态仍以 `manifest.json` 为准。README 处于 Documents 内，删除 App 也会丢失；备份时请将整个 SideloadPersist 文件夹压缩并移到应用目录之外。

## Preferences API Hook 开发实现

iOS 27.0.1 对 `Library/Preferences` 整目录的 `rename()` 返回 `EPERM`。因此不再移动该目录，也不生成周期性快照。改为在 `Documents/SideloadPersist/Data/Preferences/<SHA256(域名)>.plist` 为每个被 Hook 管理的域写入一份 canonical 二进制 Property List；写入和移除操作原子提交，删除键以墓碑记录，防止读取旧原生偏好值。首次初始化可导入原生持久域；这不会自动删除系统存储中已有的数据副本。

Hook 当前涵盖 Foundation `NSUserDefaults` 常见 typed getter/setter、object/remove、`persistentDomain`、普通 Suite；以及 `CFPreferencesCopyAppValue` / `SetAppValue` / `AppSynchronize` 和当前用户、任意主机的 `CopyValue` / `SetValue` / `Synchronize`。测试会检查 `dictionaryRepresentation` 正确隐藏已删除键、直接 CFPreferences 写入能被 NSUserDefaults 读取、跨安装对比 `cfDirect` 计数。App Group Suite、非主域及批量 CFPreferences、进程外 `cfprefsd`、绕过公开 API 的代码路径均不能保证覆盖。v3 ZIP 在导入前校验 Preferences 域文件，冷启动置换保存内容，既有 V2/V1 继续按旧机制恢复。`StorageProbe` 会显示 `PREFERENCES_HOOK_STATUS`、`SCOPE_HOOK Preferences`、`RESTORE_COMPARE userDefaults`、`defaultsSuite`、`cfPreferences`；**iOS 27 真机已验证 StorageProbe 的四种 Preferences API 计数从备份前 1、恢复后读出 1、随后更新到 2；其他 App 的兼容性仍需验证。**
### 系统偏好域隔离（v3 真机测试后修复）

StorageProbe 真机恢复验证达到 **44 PASS / 0 FAIL / 1 SKIP**，四类偏好 API 均读取到恢复前的计数。分析该轮原始备份 ZIP 又发现 **16 个**实时偏好域文件中，仅 **2 个**属于 StorageProbe；其余 **14 个**源自 `com.apple.*` 或 iOS 系统绝对路径形式的 Suite。这些系统框架偏好不应该作为注入 App 的私有内容被备份。

新版本的 `NSUserDefaults initWithSuiteName:` Hook 对 Apple/system 命名空间、App Group 和文件路径形式的偏好域改为原生处理，不写入 `Data/Preferences`。旧版本留下的这些域文件会在下一次成功初始化时**移出活动备份目录，保存到原生 `Library/Caches/SideloadPersist/ExcludedPreferences`**，不会直接删除；若隔离过程失败，则不会宣称 Preferences Hook 已成功启用。应用自身主域及普通第三方 Suite 仍按原方案处理。v3 原始恢复格式保持兼容。

**重要限制**：自动隔离仅针对当前活动的 `Data/Preferences` 文件，不会回写或清理用户已经导出的旧 ZIP，也不会修改 `Backups` 或 `Inbox/Imported` 中历史存档。旧档案可能仍含这些系统偏好副本；不要公开分享。确认新版真机检查通过并生成清洁备份之后，再根据自己的保留需求处理旧档案。系统 Caches 可能被 iOS 清理，因此隔离区仅用于避免立刻删除误收集的数据，不应当作长期备份。

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

## 自定义 Library 私有子目录（Application Support 内嵌备份）

SideloadPersist 不处理普通 Documents 用户文件，也**不**对整个 `Library` 进行重定位。Apple 允许应用在 `Library` 下建立自己的子目录，但许多框架/系统组件也使用该区域。因此采用保守的定向发现：

- 自动发现以当前 App **Bundle ID** 命名的目录，以及与长度至少五个字符的 **CFBundleName / CFBundleDisplayName** 前缀匹配的自建目录。例如 StorageProbe 的 `Library/StorageProbeCustomPersistent`。
- 如遇非标准自建目录，IPA 的 Info.plist 可以列出 `SideloadPersistAdditionalLibraryScopes`（字符串数组，只写直接子目录名），只对已存在的目标执行迁移。此配置**不影响** Application Support、WebKit、Cookies、Preferences 的默认行为。
- 如果 SideloadPersist 备份中已有过去映射的自建目录，下次冷启动会从备份自动重建原始符号链接，即使新安装时该目录还不存在。
- 绝不自动迁移 `Caches`、`Preferences`、`SplashBoard`、`Saved Application State`、`Application Support`、`WebKit`、`Cookies`、`group.*`、`com.apple.*` 及非法/非顶层目录。其他不确定来源的目录只观察、不搬移。不会递归遍历整个 Library。

自建目录的原始路径 `Library/<name>` 映射到：

```text
Documents/SideloadPersist/Data/Application Support/
  SideloadPersist.Library/<name>/
```

**这是原有 Application Support 备份范围的子目录**，因此无需改变 ZIP v3 的格式；普通手动压缩备份仍然只需要完整压缩 `Documents/SideloadPersist`。在 `manifest.json` 的 `additionalLibraryMappings` 中记录已验证的映射，自动 README 展示原路径和备份路径。`library-discovery.json` 记录筛选结果、冲突和未选中条目数量，不包含文件内容。

遇到原目录和目标都含数据、外来的符号链接或系统拒绝目录操作时，仅保留原状并记录原因；不自动合并或覆盖。新建目录一般在下一次冷启动时发现，研发测试可通过 `PDStorageRefreshOptionalMappings()` 在同一轮一键综合测试里立即触发刷新。

**验收范围**：macOS CI 增加首次迁移、冲突拒绝、ZIP v3 冷启动恢复、重装后缺少原符号链接时的重新建立、旧数据保留和系统目录未被触碰的测试。iOS 真机的自建目录迁移仍需实测，不应将其视为已验证的全量 Library 数据备份能力。

StorageProbe 的下一次单轮真机综合测试还将覆盖 `Library/StorageProbeCustomPersistent`（自动识别）与 `Library/ThirdPartyState`（通过 Info.plist 明确列入）这两种来源，并对恢复前后标记进行精确比较。两者均位于原有 Application Support 备份范围中，无需引入新的 ZIP 版本。

## 源码结构与许可

- 新架构：`PDEntry.m`、`PDStorage.m`、`PDIntro.m`、`PDArchive.m`。
- `PDGate.m`、`PDHooks.m`、`PDRedirect.m` 等为早期技术参考，**不参与当前编译**。
- 项目 MIT；`vendor/miniz` 保留原 MIT 许可；历史 fishhook 亦保留原许可证。

本项目不会包含用户证书、私钥；发布产物为未签名二进制，需使用者自行签名和安装。
