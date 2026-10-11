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
| Test | `scripts/test.sh` |
| Test incl. 100k-file perf check | `EXPLORER_PERF_TESTS=1 scripts/test.sh` |
| Build `build/Explorer.app` | `scripts/bundle.sh` |
| Signed + notarized build | `SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh && scripts/notarize.sh` |

To work in Xcode, open `Package.swift`.

## Layout
- `Sources/ExplorerCore` — UI-free model: `FileItem`, `DirectoryLoader` (fast `getattrlistbulk` path with
  `FileManager` fallback), `DirectoryWatcher` (FSEvents), `ExplorerLocation`, `NavigationHistory`.
  Must not import AppKit.
- `Sources/ExplorerApp` — AppKit UI.
- `Tests/ExplorerCoreTests` — Swift Testing suites.
