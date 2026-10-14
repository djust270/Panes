# Panes

A native macOS file manager modelled on the Windows 11 File Explorer. See [PLAN.md](PLAN.md) for the roadmap.

## Requirements
- macOS 13+
- Swift 6 toolchain (Command Line Tools are enough; Xcode optional)

## Common tasks

| Task | Command |
|---|---|
| Build | `swift build` |
| Run (unbundled) | `swift run ExplorerApp` |
| Lint | `scripts/lint.sh` (needs `brew install swiftlint`) |
| Test | `scripts/test.sh` |
| Test incl. 100k-file perf check | `EXPLORER_PERF_TESTS=1 scripts/test.sh` |
| Test incl. cross-volume ops on an exFAT disk image | `EXPLORER_VOLUME_TESTS=1 scripts/test.sh` |
| Build `build/Panes.app` | `scripts/bundle.sh` |
| Preview the app icon (drawn by `scripts/make-icon.swift`) | `swift scripts/make-icon.swift icon.png` |
| Signed + notarized build | `SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh && scripts/notarize.sh` |
| DMG from `build/Panes.app` | `VERSION=0.2.0 scripts/dmg.sh` |
| Release (app + DMG notarized, Sparkle-signed, appcast item) | `SIGN_IDENTITY=… scripts/release.sh 0.2.0 7`; `DRY_RUN=1` to try it unsigned, `PUBLISH=1` to create the GitHub release and push `appcast.xml` |
| Sort/group timings at 100k items | `EXPLORER_PERF_TESTS=1 scripts/test.sh --filter ListPerformance` |

To work in Xcode, open `Package.swift`.

## Layout
- `Sources/ExplorerCore` — UI-free model: `FileItem`, `DirectoryLoader` (fast `getattrlistbulk` path with
  `FileManager` fallback), `DirectoryWatcher` (FSEvents), `ExplorerLocation`, `NavigationHistory`, and the
  file-operation engine (`FileOperationTask`: copy/move/trash/delete/rename/create with conflicts, pause/cancel
  and undo inverses), `FileNaming`, `RecycleBin`, and the view model: `ViewMode`, `FileColumn`, `FileGrouper`,
  `FileListContent`, `FolderViewSettingsStore` (per-folder view memory), `FilePropertiesReader`, `LRUCache`,
  and UI rules kept testable: `KeyboardScheme` (Windows/Mac shortcut tables), `TypeAheadSelector`, `FileKind`
  (the Filter menu), `TabStripLayout`; Phase 6's `MountedVolume`/`DriveStore` (drive letters, mapped drives),
  `WindowsPath`, `ContentCounter`, `WindowsPermissions` (POSIX/ACL ↔ Windows permissions), `FileMetadata`,
  `Archive` and `NetworkNeighborhood`. Must not import AppKit.
- `Sources/ExplorerApp` — AppKit UI. `ExplorerWindowController` owns the title-bar tab strip; each tab is an
  `ExplorerTabController` (history, loading, commands) showing an `ExplorerRootViewController` (address bar,
  command bar, panes, status bar). `Theme` and `AppSettings` hold the Windows 11 look (and the optional Windows 98
  one, drawn with `ClassicDrawing`) and the Settings window's preferences; `MainMenu` takes every shortcut from the keyboard scheme. `PropertiesWindowController` (General,
  Security, Details tabs), `ExtractWizard`, `MapDriveDialog`, `DriveCenter` (volumes, letters, Eject),
  `NetworkBrowser` (Bonjour) and `SystemIntegration` (folder handler, Services, default file viewer).
- Phase 7: `FullDiskAccess` and `CrashReport` (ExplorerCore); `FullDiskAccessWindowController`, `LaunchAtLogin`,
  `Updater` (Sparkle), `CrashReporter` and `AppInfo` (ExplorerApp).
- `Tests/ExplorerCoreTests` — Swift Testing suites.

## Releases
Updates are delivered with [Sparkle](https://sparkle-project.org): `appcast.xml` on the main branch lists releases,
and the DMGs are GitHub release assets. Versions containing "beta" go to the beta channel. The EdDSA signing key
lives in the release machine's login keychain; keep an exported copy somewhere safe
(`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key`), since losing it means existing
installs can't verify new updates. If SwiftPM hangs resolving packages, pass `--disable-keychain`.
