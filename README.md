# Explorer for macOS

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
| Build `build/Explorer.app` | `scripts/bundle.sh` |
| Signed + notarized build | `SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh && scripts/notarize.sh` |

To work in Xcode, open `Package.swift`.

## Layout
- `Sources/ExplorerCore` — UI-free model: `FileItem`, `DirectoryLoader` (fast `getattrlistbulk` path with
  `FileManager` fallback), `DirectoryWatcher` (FSEvents), `ExplorerLocation`, `NavigationHistory`, and the
  file-operation engine (`FileOperationTask`: copy/move/trash/delete/rename/create with conflicts, pause/cancel
  and undo inverses), `FileNaming`, `RecycleBin`, and the view model: `ViewMode`, `FileColumn`, `FileGrouper`,
  `FileListContent`, `FolderViewSettingsStore` (per-folder view memory), `FilePropertiesReader`, `LRUCache`.
  Must not import AppKit.
- `Sources/ExplorerApp` — AppKit UI.
- `Tests/ExplorerCoreTests` — Swift Testing suites.
