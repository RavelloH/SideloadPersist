# SideloadPersist — iOS 数据持久化 dylib（实验性）

**v0.8：目录级重定位，不再依赖外部文件夹选择器，也不依赖证书的 Bundle ID 与 `application-identifier` 匹配。**

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

完成同步初始化后，等 App 存在一个有效前台 Scene，自动以半屏 Sheet 展示一次介绍页：当前 App 在「文件」中的目录路径、打开「文件」、导入备份 ZIP、恢复说明和完成按钮。确认完成后静默运行，不驻留悬浮按钮或轮询监听。

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

ZIP 导入支持通过系统选择器“导入副本”，以及将唯一 ZIP 放进 `SideloadPersist/Inbox/` 再点「扫描 Inbox 中的 ZIP」。若签名身份不匹配导致系统选择器失效，仍能使用 Inbox。

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
- `StorageProbe-unsigned-ipa`：测试 `NSFileManager`、`NSData`、`NSFileHandle`、POSIX `open/write/stat`、`stdio`、SQLite WAL、CoreData SQLite、NSUserDefaults；
- `PickerProbe-unsigned-ipa`：保留的文件选择器兼容性测试。

**StorageProbe 不自带 dylib。** 使用 LCSign 等工具注入 dylib、开启文件共享、签名安装，打开 StorageProbe 后按「运行存储 API 测试」，复制结果并在「文件」App 中确认 `SideloadPersist/Data/Application Support/StorageProbe` 下确实存在文件。重新启动再运行，检查文件和数据库能否继续读取。不要直接在重要 App 上测试首次目录迁移。

CI 另在 macOS 隔离 HOME 环境中验证原子迁移、符号链接路径读写、恶意 ZIP 穿越拦截、ZIP 暂存以及重新启动恢复；**这些并非 iOS 27.0.1 的真机测试**。

本地 macOS/Xcode 编译：`make all`。

## 源码结构与许可

- 新架构：`PDEntry.m`、`PDStorage.m`、`PDIntro.m`、`PDArchive.m`。
- `PDGate.m`、`PDHooks.m`、`PDRedirect.m` 等为早期技术参考，**不参与当前编译**。
- 项目 MIT；`vendor/miniz` 保留原 MIT 许可；历史 fishhook 亦保留原许可证。

本项目不会包含任何用户证书、私钥，不自动发布 Release。
