# SideloadPersist (experimental)

An **unsigned arm64 iOS dylib** for controlled sideloading experiments. It presents a folder picker on first launch, remembers its security-scoped bookmark, and maps a subset of the app's **Documents** file access to the selected folder's `Documents/` subdirectory.

## State / limitations

**v0.6 tests a LiveContainer-inspired host-identifier repair against the user's iOS 27 file-picker failure.** It defers filesystem hooks until folder authorization and includes an independent unsigned PickerProbe IPA. The host repair is OFF by default and uses a private system class, so compatibility and stability are not guaranteed.

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
- **Until directory authorization succeeds, the injected dylib does NOT install fishhook or NSFileManager method hooks.** This isolates the system picker from our redirection hooks. It does not guarantee that the host app cannot alter the picker.
- **LiveContainer-style Fix File Picker (OFF by default):** A user-toggleable experiment inspired by LiveContainer's newer fix, not its legacy Inbox copy mode. When enabled, it attempts to swizzle the private `DOCConfiguration.setHostIdentifier:` setter and supplies the bundle portion of the **actual `application-identifier` code-signing entitlement**. It never edits entitlements or accesses other app sandboxes. The hook may be unavailable on some iOS versions; inspect diagnostics for `installed=yes`, `DOCConfiguration hostIdentifier`, and the signed/plist bundle IDs. Turning the setting off disables rewriting (though an installed method shim remains until process restart). The independent PickerProbe app has the same toggle for A/B tests. **Use only on throwaway test installs; private APIs carry crash and compatibility risks.**
- The gate includes **诊断：选择一个普通文件**. Select a preexisting PDF, TXT, JSON or image file. The code only records whether a URL callback arrived (scheme/extension, not file contents); it does not activate redirection or mutate the file. This distinguishes generic document selection problems from directory-only selection problems.
- The **built-in diagnostics screen** shows timestamped logs for picker presentation, modern/legacy callbacks, security-scoped access, file coordination and bookmark saving. On the initial gate tap **查看诊断日志**. After activating a folder, tap the small **日志** button at the lower right. The screen can refresh, copy, and clear the log. Native `NSLog` output remains available with prefix `[SideloadPersist]`.
- Do not mix multiple apps into the same selected folder; each app should use a separate root.

## Build

GitHub Actions: run **Build experimental dylib** manually, or push to `main`. Two artifacts are generated: `SideloadPersist-ios-arm64-unsigned` (the injectable dylib) and `PickerProbe-unsigned-ipa` (an independent, unsigned, **unmodified** control IPA). The latter must be signed with your own device-compatible profile before installing; it contains no SideloadPersist dylib.

Local macOS Xcode command-line tools: `make all`.

The `dist/SideloadPersist.dylib` must be placed in the app's Frameworks directory, registered as a load command by an IPA injector, and re-signed with the rest of the IPA. This repository deliberately does not alter or upload any user IPA or signing certificates.

## Test

1. Back up the target app and use a disposable sample IPA with a test file in `Documents`.
2. Inject `SideloadPersist.dylib`, sign and install.
3. For diagnostic isolation, first tap **诊断：选择一个普通文件** and choose an existing file in Files / iCloud Drive. Check the resulting status and logs. Then tap **选择外部文件夹（标准）**. If the picker shows the target app's own empty folder, go back to **Browse Locations** and navigate to a dedicated subfolder in iCloud Drive or another independent provider. Tap “打开”. Grant access and observe the gate closing. If **Open** fails, cancel and try **兼容模式重试** with the *same external subfolder*.
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
- **Suggested v0.6 A/B:** In the independent PickerProbe test app, first select an ordinary file and a dedicated iCloud Drive folder with the new compatibility toggle OFF. Turn ON the LiveContainer-style fix and repeat with the same locations. If both fail, inspect whether the log says `DOCConfiguration ... installed` and whether `hostIdentifier` setter was actually intercepted. Report only the app IDs and diagnostic events, not personal file locations. Repeating in the injected CiliCili app is a secondary comparison.
- **Attribution:** The host-identifier compatibility approach is informed by LiveContainer's open source `TweakLoader/DocumentPicker.m` (LiveContainer/LiveContainer; AGPL-3.0). Our implementation was independently written in `src/PDPickerHostFix.m` using runtime lookup and Security framework, without copying LiveContainer source.
- **Still broken on v0.6:** Try the separate unsigned `PickerProbe-unsigned.ipa` signed as a new standalone app (no injection; unique Bundle ID). Compare **file** and **folder** selection there with the same provider and subfolder. If that independent app also cannot select folders, investigate File Provider or iOS behavior rather than modifying host-app hooks. Copy only needed logs and redact private paths.
- Neither the injected dylib nor the independent IPA can intercept the system-owned **Open** button tap; only picker callbacks and pending state are observable. This is compiled and smoke-tested in CI, not yet verified on iOS 27 hardware.

## Security note

The code does not attempt to bypass iOS sandboxing. It only accesses user-authorized folders. Never use another app's private data directory or assume a file-provider URL will support arbitrary POSIX operations or database concurrency.

## Licensing

Our code is MIT-licensed (see `LICENSE`). The `vendor/fishhook` directory contains Facebook's fishhook source under its original BSD-style LICENSE.
