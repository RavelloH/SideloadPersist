# 安装、备份与恢复

SideloadPersist 是供侧载工具注入的 **未签名 iOS arm64 动态库**，不是独立安装的 IPA。请只在能够承担数据丢失风险的非关键 App 上试用 Beta。

## 准备与安装

1. 在 [GitHub Releases](https://github.com/RavelloH/SideloadPersist/releases) 下载本版本的 `SideloadPersist.dylib`；不要把 StorageProbe / PickerProbe 测试 IPA 当作插件成品。
2. 使用支持 dylib 注入的 IPA 签名/侧载工具将其加入目标应用并重新签名。确保签名后的 IPA 启用了文件共享（`UIFileSharingEnabled`）和就地打开文档（`LSSupportsOpeningDocumentsInPlace`），否则文件 App 可能看不到备份目录。具体开关取决于工具。
3. 启动一次 App，让插件初始化已支持的目录，并查看首次引导。到「文件」App →「在我的 iPhone」→ 该 App → `SideloadPersist`，检查目录与状态；目录不存在或映射不完整时停止备份流程并查看诊断。
4. **先在测试 App 上验证**。不要把注入/签名成功当作数据可恢复的证明。

## 建立独立备份

1. 让 App 完成必要的写入并**完全退出**，避免 SQLite WAL、WebKit 等文件仍在更新。
2. 在文件 App 中将整个 `Documents/SideloadPersist` 文件夹压缩为 ZIP（确保包含 `Data/` 和清单），复制到目标 App 沙盒**之外**的安全存储位置。
3. 检查 ZIP 能打开、数据没有缺失；保留副本。**在独立备份验证前绝不卸载原 App。**
4. 遇到 `preferences-integrity-warning.json`、`scope-mapping-result.txt` 为 `partial`、或测试报告 `BACKUP_NOT_READY` 时，不得视作可靠备份。

## 卸载重装后恢复

1. 确认 ZIP 已保存在原 App 沙盒之外。重新签名安装目标 App，并注入相同版本或兼容版本的 SideloadPersist。
2. 启动新 App 一次完成目录初始化。将 ZIP 复制至新 App 的 `SideloadPersist/Inbox/`，或在可用时使用内置的「导入备份 ZIP」系统选择器。
3. 选择 ZIP 并查看来源 App 身份提示。来源标识不同或历史备份缺失标识时，需明确手动确认；确认并不等于备份可信。
4. 导入仅会**校验并暂存**数据；按照完成界面退出 App，随后**再次冷启动**，才会尝试应用恢复。
5. 检查 `restore-last.json` 与 App 的真实内容、数据库或设置。收据只是恢复事务状态，不代表 App 登录状态或云端数据已经恢复。继续保留原 ZIP 和 `Backups/`。

## 无法恢复时

不要反复覆盖或删除源文件。保留原 ZIP、`Backups/`、映射结果和恢复记录；在 [Issues](https://github.com/RavelloH/SideloadPersist/issues) 报告设备系统版本、签名方式、插件版本与不含个人隐私的诊断。详见 [安全说明](SAFETY.md) 与 [技术原理](ARCHITECTURE.md)。


## 备份与恢复（原始技术说明）

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
