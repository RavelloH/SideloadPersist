# SideloadPersist (experimental)

An **unsigned arm64 iOS dylib** for controlled sideloading experiments. It presents a folder picker on first launch, remembers its security-scoped bookmark, and maps a subset of the app's **Documents** file access to the selected folder's `Documents/` subdirectory.

## State / limitations

**v0.1 is a research prototype, not a universal iOS sandbox redirector.**

- Requires injection into an IPA and re-signing of the entire app and embedded frameworks with your signer. The build artifact is deliberately unsigned.
- Supports iOS 15+ at build time; actual iOS 27.0.1 behavior **not yet device-tested**.
- Shows an **overlay that blocks user interaction**. It cannot suspend an arbitrary third-party app's background threads or early application initialization.
- Only `Documents` is mapped, through `NSSearchPathForDirectoriesInDomains`, a subset of `NSFileManager` and selected POSIX calls. **Not** a transparent replacement for all file APIs, SQLite's VFS, Swift or WebKit storage.
- `Library`, preferences, caches, app groups and **Keychain are NOT redirected**.
- POSIX APIs that bypass coordination are not safe for concurrent cloud synchronization. For tests, choose an independent local file provider folder and use simple text files. **Do not test on important apps or live databases.**
- The saved bookmark lives in the original sandbox; after deleting/reinstalling, select the *same* folder again. Using a different Bundle ID is supported if the selected external folder is the same. App data not mapped from Documents remains tied to the old installation.
- Folder-picker providers may not grant the needed write permissions; failure leaves the gate visible with an error. An inaccessible/stale bookmark prompts for selection again.
- Do not mix multiple apps into the same selected folder; each app should use a separate root.

## Build

GitHub Actions: run **Build experimental dylib** manually, or push to `main`. Download the artifact `SideloadPersist-ios-arm64-unsigned`.

Local macOS Xcode command-line tools: `make all`.

The `dist/SideloadPersist.dylib` must be placed in the app's Frameworks directory, registered as a load command by an IPA injector, and re-signed with the rest of the IPA. This repository deliberately does not alter or upload any user IPA or signing certificates.

## Test

1. Back up the target app and use a disposable sample IPA with a test file in `Documents`.
2. Inject `SideloadPersist.dylib`, sign and install.
3. Start app; pick a **dedicated external folder**, grant access, then observe the gate closing.
4. Create/read a simple file using `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)` or `NSFileManager`. It should appear under `<selected folder>/Documents/`.
5. Fully restart the app. It should restore the bookmark without prompting.
6. If the app is deleted and reinstalled, it should prompt again; select the exact same folder and verify the file is still available.
7. Record Console logs tagged `[SideloadPersist]`. Compare before/after file paths.
8. Do **not** attempt to migrate an existing app by overwrite until a controlled test succeeds.

## Why not real app suspension?

A third-party injected library is loaded inside an arbitrary process. Blocking its main thread before `UIApplication` is ready prevents showing a document picker. The safe first prototype waits for an active scene and places an independent window over it. This gates interaction but not arbitrary background work.

## Licensing

Our code is MIT-licensed (see `LICENSE`). The `vendor/fishhook` directory contains Facebook's fishhook source under its original BSD-style LICENSE.
