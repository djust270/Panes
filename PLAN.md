# Explorer for macOS — Phased Plan

Goal: a native macOS file manager that mimics the look and behaviour of the Windows 11 File Explorer.

## Key technical decisions

| Decision | Choice | Why |
|---|---|---|
| Language / UI | **Swift + AppKit**, SwiftUI only for simple panels | `NSOutlineView` / `NSTableView` / `NSCollectionView` scale to 100k+ items, allow pixel-level control of the Windows look, and give fine-grained keyboard & focus control. |
| Project format | **Swift Package Manager** (`Package.swift`) | Builds with Command Line Tools alone (no Xcode required); opens directly in Xcode when available. `scripts/bundle.sh` wraps the binary into a `.app`. |
| Tests | **Swift Testing** (`import Testing`) | Ships with the toolchain; XCTest requires full Xcode. |
| Min OS | macOS 13+ | `QLThumbnailGenerator`, modern `NSVisualEffectView` materials, Swift concurrency. |
| Distribution | **Developer ID + notarization (not Mac App Store)** | A file manager needs unrestricted file access; sandboxing would force a permission prompt for every folder. |
| Icons | Microsoft **Fluent UI System Icons** (MIT) | Windows 11 look, legal to ship. The Segoe Fluent Icons font and real Windows shell icons are not redistributable. |
| Font | SF Pro by default; Segoe UI if the user has it installed | Segoe UI cannot be bundled. |
| Target look | Windows 11 Explorer (tabs, command bar, Mica-style background) | Current Windows design; a Windows 10 "Ribbon" theme could be added later. |

## Architecture

```
Sources/
  ExplorerCore/   No UI. File model, directory loading, FSEvents watching,
                  locations, navigation history, (later) file-operation engine.
  ExplorerApp/    AppKit UI. Windows, panes, views, menus.
Tests/
  ExplorerCoreTests/
```

`ExplorerCore` must never import AppKit so it stays fully unit-testable.

---

## Phase 0 — Foundations (~1 week)
- [x] Swift package: `ExplorerCore` library, `ExplorerApp` executable, `ExplorerCoreTests`
- [x] Core layering: `FileItem`, async `DirectoryLoader`, FSEvents `DirectoryWatcher`
- [x] `ExplorerLocation` abstraction (real folders + virtual: Home, This PC, Network, Recycle Bin, Search)
- [x] `NavigationHistory` (back/forward stacks with dropdown lists)
- [x] Empty AppKit window with split-view skeleton and standard menus
- [x] `scripts/bundle.sh` (build `.app`, ad-hoc or Developer ID signing), `scripts/notarize.sh`
- [x] CI (GitHub Actions: build, test, SwiftLint)

**Exit criteria:** empty window launches; Core tests pass; enumerating a 100k-file folder takes < 1 s
(`EXPLORER_PERF_TESTS=1 scripts/test.sh`).

**Status: complete.** 100k files enumerate in ~0.35 s (debug build) via `getattrlistbulk`; the `FileManager`
path took ~1.2 s and is kept as a fallback for file systems that don't support bulk reads.

## Phase 1 — Core browsing (~2–3 weeks)
- Window layout: navigation pane (left) | content | status bar
- Navigation pane `NSOutlineView`: Home, Desktop/Downloads/Documents/Pictures/Music/Videos, **This PC** (volumes as "drives"), Network — lazily expanded
- **Details view** (`NSTableView`): Name, Date modified, Type, Size; sortable, resizable columns
- **Address bar**: breadcrumb segments with chevron dropdowns; click empty space → editable path text
- Back / Forward / Up / Refresh with history dropdowns
- Enter/double-click opens files via `NSWorkspace`, enters folders; packages (`.app`) treated as files
- Live refresh via FSEvents; respect hidden flags (toggle)
- Status bar: "N items | M items selected 1.2 MB"

**Exit criteria:** browse the whole disk keyboard-only; external changes appear live.

## Phase 2 — File operations (~3 weeks)
- [x] Cut / Copy / Paste with real Windows "cut" semantics (dimmed cut items, move on paste)
- [x] Rename in place (F2, selects name without extension), New Folder, New → Text file
- [x] Delete → Trash; Shift+Delete → permanent delete with confirmation
- [x] **Operation engine**: queued background operations, Windows-style progress dialog (speed graph, pause/cancel), "Replace or Skip Files" conflict dialog with "Compare info"
- [x] Undo/Redo (Ctrl+Z / Ctrl+Y) for rename, move, copy, delete
- [x] Drag & drop within the app, with Finder, and with other apps (Ctrl = copy, Shift = move)
- [x] Recycle Bin virtual location (`~/.Trash` + per-volume trashes) with Restore / Empty

**Exit criteria:** correct behaviour across volumes (APFS, exFAT, SMB), including cancel mid-operation and conflicts.

**Status: complete** (checked by hand). File operations on SMB shares are still untested.
- Engine (`FileOperationTask`) is covered by unit tests on APFS, and by `EXPLORER_VOLUME_TESTS=1 scripts/test.sh`
  against a real exFAT disk image: cross-volume move + undo, xattrs surviving exFAT, cancel mid-file removing the
  partial copy, case-insensitive conflicts.
- Copies use `copyfile(3)` (APFS clones when possible); replacements are copied beside the original and swapped in,
  so a cancelled replace keeps the old file.
- Operations run concurrently (as on Windows), each on its own thread, rather than strictly queued.
- Undo/redo is app-wide (`UndoManager`), ⌘Z / ⇧⌘Z for now; Ctrl+Z / Ctrl+Y arrive with Phase 4's keyboard scheme.
  Undoing a copy or a new item moves it to the Trash; replaced files are not restored.
- Recycle Bin reads `~/.Trash` and per-volume `.Trashes/<uid>`. Restore uses Finder's "Put Back" records from the
  Trash's `.DS_Store` and this app's own log. Listing `~/.Trash` requires Full Disk Access (Phase 7 onboarding);
  without it the view explains this.
- Pulled forward from Phase 6: the address bar accepts `\\server\share\folder`, `//server/share` and
  `smb://` / `afp://` / `nfs://` URLs, mounting via NetFS (system sign-in dialog, share picker for a bare server)
  or reusing an existing mount.

## Phase 3 — Views & panes (~3 weeks)
- [x] View modes: Extra large / Large / Medium / Small icons, List, Details, Tiles, Content (`NSCollectionView` custom layouts)
- [x] Async thumbnails via `QLThumbnailGenerator` with an LRU cache
- [x] Sort by / Group by with collapsible group headers ("Today", "Last week", "A–H", Type…)
- [x] Column chooser (right-click header): Date created, Tags, Dimensions, Duration…
- [x] Per-folder view memory + "Apply to all folders"
- [x] **Preview pane** (`QLPreviewView`) and **Details pane** (metadata + thumbnail)
- [x] Item checkboxes, ⌘/Shift multi-select, rubber-band select, Select all / none / invert
- [ ] Ctrl+click to toggle selection — moved to Phase 4's Windows keyboard scheme (on the Mac, Ctrl+click is right-click)

**Status: complete** (checked by hand), apart from Ctrl+click.
- Details stays an `NSTableView` (group headers are group rows); the other seven layouts share one `NSCollectionView`
  with a flow layout per mode. Both render `FileListContent` (ExplorerCore: sort → group → collapse), and selection
  is kept by URL so it survives reloads and layout switches. Layouts are ⌘1…⌘8 (Windows' Ctrl+Shift+1…8 would
  clash with ⌘⇧3–5 screenshots), plus the View menu, the background context menu and the status-bar buttons.
- List view scrolls sideways in columns; when grouped it scrolls vertically instead.
- Groups use Windows 11's buckets (Today … A long time ago, A - H …, Tiny … Gigantic, Unspecified last). Clicking a
  header selects its items; the chevron collapses it. No Group by Tags (an item can have several).
- Thumbnails (Medium icons and up, Tiles, Content, Details pane) come from `QLThumbnailGenerator`, cached in an LRU
  bounded at 256 MB of pixels; files without one keep their type icon and aren't retried.
- Extra columns: Date created, Tags, Dimensions, Duration. Tags/dimensions/duration are read only when shown or
  sorted on (`FilePropertiesReader`: Spotlight, with an image-header fallback for dimensions on unindexed volumes;
  duration needs Spotlight). Header right-click: Size column to fit, Size all columns to fit, column chooser.
- Per-folder memory (`FolderViewSettingsStore`, up to 2000 folders, least recently changed forgotten): layout, sort,
  grouping, visible columns and their order. Column widths are app-wide. View › Apply View to All Folders /
  Reset All Folders…; the Recycle Bin and This PC keep their own views.
- Preview pane (⌥⌘P) and Details pane (⇧⌥⌘P) share a collapsible right-hand split item; the choice is app-wide.
- Item check boxes (View menu) toggle an item without touching the rest of the selection. Rubber-band selection
  works in every layout; in Details it starts from empty space or any column but Name (dragging a name drags the
  files). Edit › Select None (⌥⌘A) and Invert Selection (⇧⌘I).
- **Ctrl+click to toggle is deferred to Phase 4's Windows keyboard scheme**: on the Mac, Ctrl+click is right-click.
  ⌘-click and ⇧-click work now.

## Phase 4 — Windows 11 look (~2–3 weeks)
- Mica-style translucent background, Windows 11 corner radii & spacing, optional custom caption bar (min/max/close on the right)
- **Tabs** in the title bar (new, close, reorder, drag tab out to new window)
- **Command bar**: New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾, Filter, ⋯
- **Context menu**: Windows 11 compact icon row + "Show more options" (Open with, Send to, Compress to ZIP, Copy as path, Properties)
- **Keyboard scheme** setting: Windows (Ctrl-based) vs Mac (Cmd-based); F2, F5, Alt+←/→/↑, Ctrl+L, Ctrl+N, Ctrl+Shift+N, Ctrl+T/W, Backspace = Up, type-ahead select
- Light / dark modes, Windows accent colours

## Phase 5 — Home, Quick Access & Search (~2 weeks)
- Home page: Quick Access tiles (pinned + frequent folders), Favorites, Recent files (Spotlight + app history)
- "Pin to Quick Access" / "Pin to Home"
- Search box scoped to the current folder: Spotlight (`NSMetadataQuery`) with fallback walk for non-indexed volumes; `kind:`, `date:`, `size:` filters; search-results view

## Phase 6 — Advanced features (~3–4 weeks)
- **Properties dialog**: General (size, size on disk, contains, attributes), Security (POSIX/ACL in Windows-like form), Details
- Compress to ZIP / Extract All wizard
- Network: Bonjour/SMB browsing, "Map network drive" via `NetFS`, `\\server\share` paths in the address bar
- This PC: drive tiles with capacity bars, Eject, optional "drive letter" labels
- Open with ▸, Set default app, "Open in Terminal", Copy as path (Windows & POSIX)
- Register as folder handler / Services provider ("Reveal in Explorer" from other apps)
- Optional dual-pane mode

## Phase 7 — Polish & release (~2 weeks)
- Performance profiling (100k+ item folders, network shares, slow external drives)
- Accessibility (VoiceOver labels, full keyboard navigation)
- First-run onboarding for Full Disk Access (with clear explanation)
- Settings: keyboard scheme, theme, show extensions, show hidden files, launch at login
- Sparkle auto-updates, DMG packaging, notarization
- Crash reporting, beta channel

---

## Risks
1. **Finder cannot be fully replaced** — macOS still uses Finder for the Desktop, "Show in Finder" from other apps, and the Trash. Aim to be the best "open folder" target, not a full replacement.
2. **TCC / Full Disk Access** — without it, Mail, Safari data, other users' folders etc. are blocked; onboarding must handle this gracefully.
3. **Trademarks** — don't use "Windows" or Microsoft logos in the app name/icon. Fluent System Icons are fine; Segoe and Windows shell icons are not.
4. **File operations on network / external volumes** — SMB/exFAT quirks (no xattrs, case-insensitivity, partial copies). Budget extra testing time for the operation engine.

**Rough total:** 18–22 weeks for one experienced macOS developer. Usable MVP (Phases 0–2 + Details view + tabs) in ~7–8 weeks.
