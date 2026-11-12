# SideloadPersist

**让侧载 iOS 应用的数据更容易备份与恢复。**

SideloadPersist 是一款面向 iOS 侧载应用的开源动态库（`dylib`）。注入目标 App 后，它会将部分私有数据放入应用「文件」目录中可访问的位置，帮助你在重新签名、卸载重装等场景下**手动备份和尝试恢复**数据。

[![Beta](https://img.shields.io/badge/status-public%20beta-orange)](https://github.com/RavelloH/SideloadPersist/releases)
[![Release](https://img.shields.io/github/v/release/RavelloH/SideloadPersist?include_prereleases&label=release)](https://github.com/RavelloH/SideloadPersist/releases)
[![Build](https://github.com/RavelloH/SideloadPersist/actions/workflows/build.yml/badge.svg)](https://github.com/RavelloH/SideloadPersist/actions/workflows/build.yml)
[![License](https://img.shields.io/github/license/RavelloH/SideloadPersist)](LICENSE)

> **Beta 提示：** 当前版本仍处于公开测试阶段。已经通过专用测试 App 的跨安装恢复验证，但不保证适用于所有第三方 App。**卸载应用会同时删除应用内的 `Documents/SideloadPersist` 文件夹；请务必先将备份复制到应用沙盒之外。**

## 能做什么

- **为重装做准备**：将受支持的应用数据集中在 `Documents/SideloadPersist/`，便于通过「文件」App 备份。
- **覆盖多种存储方式**：支持 Application Support、WebKit、Cookies，以及部分 NSUserDefaults / CFPreferences 偏好数据；可识别部分应用自建的 Library 目录。
- **导入历史备份**：支持 ZIP 导入与冷启动恢复，并保留旧数据用于排查或回退；兼容旧版 v1 / v2 备份。
- **尽量避免误覆盖**：对目录冲突、来源 App 身份异常和偏好写入失败给出保护与提示，而非无条件合并数据。

<details>
<summary>English summary</summary>

SideloadPersist is an open-source, injectable iOS `dylib` for **manual backup and recovery of selected app-private data** across sideloaded app reinstalls. It supports Application Support, WebKit, Cookies, selected preferences APIs, and some app-owned Library folders. This public beta is experimental: it does not preserve Keychain, App Groups, or every app's data, and it **does not survive uninstallation unless you export a backup outside the app's sandbox first**.

</details>

## 获取与开始使用

1. 从 **[Releases](https://github.com/RavelloH/SideloadPersist/releases)** 获取最新 Beta 的 **未签名 `SideloadPersist.dylib`**。
2. 使用支持动态库注入的 IPA 签名工具将它加入目标 App，并为签名后的 App 启用文件共享。
3. 首次启动后，按照引导找到「文件」→「在我的 iPhone」→ 对应 App → `SideloadPersist`。
4. 完全退出 App，**将整个 `SideloadPersist` 文件夹备份到该 App 之外**。需要恢复时，重新安装并注入插件、导入 ZIP、退出后再次启动，再检查实际数据。

详细步骤见 **[安装、备份与恢复指南](docs/BACKUP-RESTORE.md)**。下载的 `StorageProbe` / `PickerProbe` IPA 是独立测试应用，**不会预装插件**，也不是可直接使用的注入成品。

## 适用范围与限制

构建目标为 **iOS 15+ / arm64**。iOS 27 真机上的 StorageProbe 已验证包括 SQLite/CoreData、WebKit 与常见偏好 API 在内的多类数据跨安装恢复；这不等于任意 App、签名身份或 iOS 版本已通过兼容性测试。

**不保证迁移** Keychain、App Groups、系统管理的数据目录、Caches、临时目录，或依赖服务器认证的登录状态。存储内容可能含有账号令牌与 Cookie，请妥善保护导出的 ZIP。建议仅在有独立备份的非关键 App 上参与测试。

了解更多：[安全边界](docs/SAFETY.md) · [Beta 验收状态](docs/BETA-STATUS.md) · [提交问题](https://github.com/RavelloH/SideloadPersist/issues)

## 文档

| 文档 | 内容 |
| --- | --- |
| [安装、备份与恢复](docs/BACKUP-RESTORE.md) | 注入准备、ZIP 备份、重装恢复与故障处理 |
| [技术架构](docs/ARCHITECTURE.md) | 数据目录重定位、Preferences Hook、恢复格式与事务机制 |
| [集成与引导界面](docs/INTEGRATION.md) | 注入时序、首次引导与文件共享前提 |
| [测试与验证](docs/TESTING.md) | StorageProbe、PickerProbe、macOS CI 与真机验收流程 |
| [安全与完整性](docs/SAFETY.md) | 数据风险、支持边界和恢复状态判定 |
| [Beta 验收状态](docs/BETA-STATUS.md) | 已验证范围、已知限制与后续验证清单 |
| [更新记录](CHANGELOG.md) | 已发布版本与主要变化 |

## 参与反馈

欢迎通过 [GitHub Issues](https://github.com/RavelloH/SideloadPersist/issues) 反馈可复现的问题，并附上 iOS 版本、签名/注入方式、插件版本及**脱敏**诊断。请勿公开上传包含个人数据、Cookie、令牌或账号信息的备份 ZIP。

项目由 [RavelloH](https://github.com/RavelloH) 维护，采用 [MIT License](LICENSE)。`vendor/` 中的第三方组件遵循各自的许可声明。
