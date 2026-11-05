# SideloadPersist (experimental)

An **unsigned arm64 iOS dylib** for controlled sideloading experiments. It presents a folder picker on first launch, remembers its security-scoped bookmark, and maps a subset of the app's **Documents** file access to the selected folder's `Documents/` subdirectory.

## State / limitations

**v0.4 adds a standard/compatibility folder picker experiment and improved diagnostics, but remains a research prototype, not a universal iOS sandbox redirector.**

- Requires injection into an IPA and re-signing of the entire app and embedded frameworks with your signer. The build artifact is deliberately unsigned.
- Supports iOS 15+ at build time; actual iOS 27.0.1 behavior **not yet device-tested**.
- Shows a **full-screen modal gate inside the host app's own UIWindow hierarchy**. Earlier builds used a separate elevated UIWindow and could interfere with the document picker. This change has compiled successfully but is **not yet verified on iOS 27**. The gate cannot suspend arbitrary third-party app background threads or early application initialization.
- Only `Documents` is mapped, through `NSSearchPathForDirectoriesInDomains`, a subset of `NSFileManager` and selected POSIX calls. **Not** a transparent replacement for all file APIs, SQLite's VFS, Swift or WebKit storage.
- `Library`, preferences, caches, app groups and **Keychain are NOT redirected**.
- POSIX APIs that bypass coordination are not safe for concurrent cloud synchronization. For tests, choose an independent local file provider folder and use simple text files. **Do not test on important apps or live databases.**
- The saved bookmark lives in the original sandbox; after deleting/reinstalling, select the *same* folder again. Using a different Bundle ID is supported if the selected external folder is the same. App data not mapped from Documents remains tied to the old installation.
- Folder-picker providers may not grant the needed write permissions; failure leaves the gate visible with an error. The gate rejects choosing a folder within the target app's own sandbox, since this would not survive uninstall. An inaccessible/stale bookmark prompts for selection again.
- When the native picker appears inside the target app's **own** location (such as “On My iPhone / AppName”), tap Back to the location browser and choose a **different** durable provider folder, e.g., a dedicated test folder on iCloud Drive. Do not assume the current app's root is a selectable external directory.
- To investigate an unresponsive **Open** button, the gate provides **选择外部文件夹（标准）** (the officially documented folder picker with default system presentation) and **兼容模式重试** (deprecated open-mode initializer with over-full-screen presentation). The compatibility mode is exploratory, not guaranteed to fix an iOS File Provider issue. Neither mode can capture the native button tap; diagnostics record successful URL delivery, cancellation and prolonged pending state.
- The **built-in diagnostics screen** shows timestamped logs for picker presentation, modern/legacy callbacks, security-scoped access, file coordination and bookmark saving. On the initial gate tap **查看诊断日志**. After activating a folder, tap the small **日志** button at the lower right. The screen can refresh, copy, and clear the log. Native `NSLog` output remains available with prefix `[SideloadPersist]`.
- Do not mix multiple apps into the same selected folder; each app should use a separate root.

## Build

GitHub Actions: run **Build experimental dylib** manually, or push to `main`. Download the artifact `SideloadPersist-ios-arm64-unsigned`.

Local macOS Xcode command-line tools: `make all`.

The `dist/SideloadPersist.dylib` must be placed in the app's Frameworks directory, registered as a load command by an IPA injector, and re-signed with the rest of the IPA. This repository deliberately does not alter or upload any user IPA or signing certificates.

## Test

1. Back up the target app and use a disposable sample IPA with a test file in `Documents`.
2. Inject `SideloadPersist.dylib`, sign and install.
3. Start app; tap **选择外部文件夹（标准）**. If the picker shows the target app's own empty folder, go back to **Browse Locations** and navigate to a dedicated subfolder in iCloud Drive or another independent provider. Tap “打开”. Grant access and observe the gate closing. If **Open** fails, cancel and try **兼容模式重试** with the *same external subfolder*.
4. Create/read a simple file using `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)` or `NSFileManager`. It should appear under `<selected folder>/Documents/`.
5. Fully restart the app. It should restore the bookmark without prompting.
6. If the app is deleted and reinstalled, it should prompt again; select the exact same folder and verify the file is still available.
7. Record Console logs tagged `[SideloadPersist]`. Compare before/after file paths.
8. Do **not** attempt to migrate an existing app by overwrite until a controlled test succeeds.

## Why not real app suspension?

A third-party injected library is loaded inside an arbitrary process. Blocking its main thread before `UIApplication` is ready prevents showing a document picker. The current prototype waits for a foreground active scene, then presents a full-screen modal from the **host app's view controller** and presents the system directory picker from that modal. This prevents an alert-level UIWindow from potentially intercepting picker touches, but it gates **user interaction only**, not arbitrary background work.

## Troubleshooting native folder selection

- **Tapping “打开” does nothing:** If still inside “On My iPhone / <AppName>”, go back to the Files location browser and choose a dedicated folder from another provider. Some locations or provider roots do not support external folder grants.
- **The document picker never returns:** Cancel/back out of the Files picker, tap **查看诊断日志**, then **刷新** and **复制**. Check for `Directory picker presented` followed by `Picker returned ...`. If the second entry is absent, the picker did not invoke its delegate and the issue is in the presentation / provider / iOS interaction, not file redirection. If the app crashes or must be relaunched, log history normally survives in its **Library/Application Support/SideloadPersist/diagnostics.log**.
- **The picker returns but activation fails:** Read the new displayed validation error and logs for security-scoped access, file coordination and bookmark saving.
- **Still broken on v0.4:** Please report the target app, the actual provider and child folder tested (avoid personal folder names), the standard/compatibility mode used, whether the picker dismisses, and the copied diagnostics. This is compiled and smoke-tested but not yet verified working on iOS 27 hardware.

## Security note

The code does not attempt to bypass iOS sandboxing. It only accesses user-authorized folders. Never use another app's private data directory or assume a file-provider URL will support arbitrary POSIX operations or database concurrency.

## Licensing

Our code is MIT-licensed (see `LICENSE`). The `vendor/fishhook` directory contains Facebook's fishhook source under its original BSD-style LICENSE.
