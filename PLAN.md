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
- Undo/redo is app-wide (`UndoManager`); Ctrl+Z / Ctrl+Y came with Phase 4's keyboard scheme.
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
- [ ] Mica-style translucent background, Windows 11 corner radii & spacing, optional custom caption bar (min/max/close on the right)
- [ ] **Tabs** in the title bar (new, close, reorder, drag tab out to new window)
- [ ] **Command bar**: New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾, Filter, ⋯
- [ ] **Context menu**: Windows 11 compact icon row + "Show more options" (Open with, Send to, Compress to ZIP, Copy as path, Properties)
- [ ] **Keyboard scheme** setting: Windows (Ctrl-based) vs Mac (Cmd-based); F2, F5, Alt+←/→/↑, Ctrl+L, Ctrl+N, Ctrl+Shift+N, Ctrl+T/W, Backspace = Back, type-ahead select
- [ ] Light / dark modes, Windows accent colours
- [ ] Ctrl+click toggles selection (Windows scheme), carried over from Phase 3
- [ ] Fluent UI System Icons — not started; SF Symbols for now

**Status: implemented, not yet checked by hand.** Driven by a temporary in-app self-test (tabs, shortcuts with real
key events, context menu, type-ahead, Ctrl+click, detaching and moving tabs, settings); the visual look still
needs checking by eye.
- Layout: title-bar tab strip; then the address bar and command bar on a lighter header layer; then the panes on a
  solid body. The window background is a behind-window `NSVisualEffectView` (closest macOS match to Mica: tinted by
  the wallpaper, solid when inactive). No `NSToolbar`: a toolbar swallows clicks in the title bar, so the strip sits
  in the content view under the transparent title bar and the traffic lights are moved down to centre on it.
- Tabs: each tab is an `ExplorerTabController` with its own history, panes and view; the window forwards commands
  to the selected tab. New (Ctrl+T, +), close (Ctrl+W, ×, middle-click), Ctrl+Tab / Ctrl+Shift+Tab, Ctrl+1…9,
  reorder by dragging, drag onto another window's strip to move it, drop anywhere else for a new window. Tab context
  menu: duplicate, move to new window, close others / to the right. Folders open in a new tab by middle-click or
  "Open in new tab" (content and navigation pane). Hovering a file drag over a tab switches to it. New tabs open the
  home folder until Phase 5's Home page.
- Caption buttons: Settings › "Window buttons on the right" swaps the traffic lights for Windows-style minimise /
  maximise / close (off by default).
- Command bar: New ▾ | Cut, Copy, Paste, Rename, Share, Delete | Sort ▾, View ▾ (layouts, Compact view, Show ▸) |
  Filter ▾ (Folders, Documents, Pictures, Music, Videos, Compressed, Applications; per tab, cleared on navigation)
  | ⋯, with Details on the right. Buttons validate like menu items; Share, Filter and separators drop out first
  when narrow.
- Context menu: icon row (Cut, Copy, Rename, Share, Delete), Open, Open in new tab / window, Open with ▸,
  Compress to ZIP file (`ditto` for one item, `zip` for several; no undo yet), Copy as path (quoted, one per line;
  the address bar accepts quoted paths), Show more options ▸ (Send to ▸ Desktop / Documents / Downloads / Mail /
  external drives, Cut, Copy, Delete, Rename). Properties waits for Phase 6's dialog.
- Keyboard: `KeyboardScheme` (ExplorerCore) holds both tables; menus are rebuilt when the scheme changes. The
  Windows scheme (default) shows Ctrl keys and keeps every ⌘ shortcut as a hidden alternate; the Mac scheme adds
  only F2/F5. Undo/Redo are Ctrl+Z / Ctrl+Y. Backspace goes **Back** (Windows Vista and later), not Up; Alt+↑ is
  Up. Layouts are Ctrl+Shift+1…8 under the Windows scheme, ⌘1…8 under the Mac one. AppKit's key-equivalent matching
  breaks with Shift (Ctrl+Shift+1 misses "⌃⇧1", plain Ctrl+1 *hits* it, Ctrl+Shift+N misses "⌃⇧N"), so a key
  monitor looks up any shortcut with Shift, or with a digit or symbol, by unshifted key and exact modifiers.
  Type-ahead works in every layout (repeat a letter to cycle). Del deletes, Shift+Del deletes permanently.
- Theme: Light / Dark / system; accent from Windows' palette or "Match macOS", used for selection, focus marks and
  tabs. Lists use Windows 11's rounded, lightly tinted selection with hover highlight; the navigation pane uses a
  neutral grey. Compact view tightens Details and navigation rows (30 → 22 pt). Segoe UI is used if installed.
- Hidden items and the navigation pane are now app-wide settings, as on Windows.

## Phase 5 — Home, Quick Access & Search (~2 weeks)
- [x] Home page: Quick Access tiles (pinned + frequent folders), Favorites, Recent files (Spotlight + app history)
- [x] "Pin to Quick Access" / "Pin to Home" (Windows 11's "Add to Favorites" for files)
- [x] Search box scoped to the current folder: Spotlight (`NSMetadataQuery`) with fallback walk for non-indexed volumes; `kind:`, `date:`, `size:` filters; search-results view
- [ ] Reorder pins by dragging in the navigation pane (`QuickAccessStore.movePin` exists; no UI yet)

**Status: implemented, not yet checked by hand.** Driven by a temporary in-app self-test (Home, Ctrl+F and typing,
refining, Escape, pattern search, pinning, Home context menus, new tab); Home and search results checked in
light/dark snapshots.
- Home is the default for new windows and tabs (Settings › "Open Explorer to": Home / This PC / your home folder),
  and Go › Home. It's a fixed layout in the collection view: Quick access as tiles (folder, parent, "Pinned"), then
  Favorites and Recent as rows (Name | date used | folder). Groups collapse; view, sort and group commands are off.
- Quick access (`QuickAccessStore`, ExplorerCore): pins start as Desktop … Videos and are the navigation pane's
  folders, as on Windows 11 (pin / unpin from item and navigation pane context menus). Frequent folders: two or
  more visits, ranked by count weighted by how recent the last visit was (up to 10); "Remove from Quick access"
  hides one for good. Entries are keyed by path, so a trailing slash doesn't make a different folder.
- Recent: files with a Spotlight "last used" date in the past 30 days in the home folder (not ~/Library, hidden
  folders, or package contents, nor folders and apps), merged with files opened from the app; 20 shown, favorites
  excluded. "Remove from Recent" hides a file until it's used again. Spotlight gets 3 s before Home shows without it.
- Search box (Ctrl+F / Ctrl+E / F3, ⌘F) on the right of the address bar: "Search <place>"; searches 0.4 s after
  typing stops, or on Return; refining replaces the search in the history; Escape or clearing goes back; ↓ moves
  to the results. Scope: the folder; the home folder from Home; every local volume from This PC; off in the Recycle
  Bin and Network.
- Query syntax (`SearchQuery`): words must all appear (case- and accent-insensitive), "quoted phrases", `*`/`?`
  patterns over the whole name, `kind:` (folder, document, picture, music, video, compressed, app — and synonyms),
  `date:`/`datemodified:` (today … last year, `2024-05-01`, `>`/`>=`/`<`/`<=`, `a..b`), `size:` (Windows' empty …
  gigantic, `>10MB`, `1.5GB`, `a..b`; 1 KB = 1024 bytes), `ext:`. Unknown `key:value` words are searched as text.
  `kind:document` no longer counts source code as a document (the Filter menu too).
- Engine (`FileSearch`): Spotlight on local internal volumes (name, or a word in the contents; live updates), with
  ~/Library and hidden folders left out unless searching inside them; a breadth-first name walk elsewhere
  (external, disk-image and network volumes), not entering packages. Results are capped at 10,000.
- Results view: Details with Name, Date modified, Type, Size and **Folder** (sortable and groupable, search-only),
  remembered once for all searches; Content view shows the folder under the name. "Searching…" in the status bar.
  Context menu adds "Open file location"; cut/copy/delete/rename/share work, and moved or deleted items drop out.
- Fixed on the way: the collection view kept stale data while Details was showing, so switching to a layout with
  more sections (Home) threw inside AppKit; it's now reloaded before its layout changes.

## Phase 6 — Advanced features (~3–4 weeks)
- [x] **Properties dialog**: General (size, size on disk, contains, attributes), Security (POSIX/ACL in Windows-like form), Details
- [x] Compress to ZIP / Extract All wizard
- [x] Network: Bonjour/SMB browsing, "Map network drive" via `NetFS`, `\\server\share` paths in the address bar
- [x] This PC: drive tiles with capacity bars, Eject, optional "drive letter" labels
- [x] Open with ▸, Set default app, "Open in Terminal", Copy as path (Windows & POSIX)
- [x] Register as folder handler / Services provider ("Reveal in Explorer" from other apps)
- [x] Optional dual-pane mode

**Status: implemented, not yet checked by hand.** Driven by a temporary in-app self-test (This PC, Properties for a
file, a folder, several items and drives, Extract All, Network, Map network drive against a mounted SMB share,
dual pane, launching with a folder and revealing a file in the bundled app), with snapshots in light and dark.
Not exercised: the Services menu entries (need `pbs -update` on a bundled build), "Show in Finder" with Explorer
as the default file viewer, Bonjour discovery (no server here advertises SMB), and Eject.
- This PC: "Devices and drives" and "Network locations" groups (fixed, sorted by the view's sort). Tiles (the
  default) show a capacity bar, red above 90% full, and "X free of Y"; Details has Name, Type (Local Disk,
  Removable Disk, Network Drive), Total Size and Free Space. Free space counts purgeable space on APFS, as Finder
  does. Updates live on mount, unmount and rename; a tab showing an ejected drive goes to This PC. Eject /
  Disconnect from the item and navigation pane menus.
- Drive letters (Settings, off by default): the startup disk is C:, other disks take the first free letter from
  D:, network drives from Z: down; a volume gets its letter back when remounted (by volume UUID, or by share for
  network volumes), and when all are taken the longest-gone volume's letter is reused (`DriveStore`).
- Properties (Alt+Enter, ⌘I under the Mac scheme; File menu, context menus, ⋯, navigation pane): one dialog per
  selection, OK / Cancel / Apply. General: editable name (a rename with undo), type, "Opens with … Change…" (sets
  the default app for the type right away, as Windows does), location, size and size on disk (folders count as
  you watch; packages count as one file), contains, created / modified / accessed, Read-only (= Locked) and
  Hidden, tri-state for several items. Drives: type, file system, share, used / free with a ring chart.
  Security: owner, group and Everyone from the POSIX bits plus access control entries, mapped onto Full control,
  Modify, Read & execute, List folder contents, Read, Write and Special permissions with Allow/Deny; the owner
  can change the POSIX rows (Windows-style cascading checkboxes), ACL rows are read-only. Details (files):
  Spotlight metadata under Description, Origin, Image, Camera, GPS, Media, Audio, Content, then File.
- Extract All… (context menu, File menu, ⋯) for .zip (`ditto`, keeps resource forks) and tar, gz/bz2/xz, 7z, RAR,
  xar, cpio (`bsdtar`): the Windows wizard (destination, "Show extracted files when complete"), extracted into a
  staging folder on the destination's volume and moved in by the operation engine, so clashes get Replace or
  Skip. Cancellable; not undoable (nor is Compress).
- Open with ▸ Choose another app… has "Always use this app to open .ext files". Open in Terminal on folders and
  the background. Copy as Windows path (Show more options, Edit menu): `\\server\share\…` on SMB shares, `D:\…`
  with drive letters.
- Network: computers advertising SMB or AFP over Bonjour, plus the servers of mounted shares and mapped drives
  (most NAS boxes and Windows PCs don't advertise). Opening one connects with the system's share picker.
- Map network drive… (This PC, Network, navigation pane, ⋯, Go menu): drive letter, folder (`\\server\share` or a
  URL, with known servers suggested), "Reconnect when Explorer starts" (silently, no sign-in prompt) and
  "Connect using different credentials". Disconnect forgets the mapping.
- Folder handler: the bundle declares folders and volumes as viewable (rank Alternate), so Explorer is in Finder's
  Open With; opened folders get a tab in the frontmost window, opened files are revealed (folder opened, files
  selected). Services: "Open in Explorer" (folders) and "Reveal in Explorer" (anything). Settings › "Open folders
  and “Show in Finder” in Explorer" makes it the default for `public.folder` and the `NSFileViewer`, and handles
  the reveal Apple event; off by default, only available from the bundle.
- Dual pane (View menu, View ▾ › Show): a second, independent pane beside the selected tab (no navigation or side
  pane, not in the tab strip), forgotten when turned off. Copy / Move to other pane (Edit menu, Show more
  options), Go › Switch to Other Pane; drag and drop works between panes as anywhere else.
- Fixed on the way: Properties tabs start at their real size (AppKit otherwise logged conflicting constraints);
  non-APFS volumes aren't asked for purgeable space (CacheDelete errors in the log).

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
