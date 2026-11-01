# Panes — Phased Plan

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
- [x] Reorder pins by dragging in the navigation pane (drop between pins; Home follows the new order)

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
- [x] Performance profiling (100k+ item folders, network shares, slow external drives)
- [x] Accessibility (VoiceOver labels, full keyboard navigation)
- [x] First-run onboarding for Full Disk Access (with clear explanation)
- [x] Settings: keyboard scheme, theme, show extensions, show hidden files, launch at login
- [x] Sparkle auto-updates, DMG packaging, notarization (scripts; no Developer ID on this Mac yet)
- [x] Crash reporting, beta channel

**Status: implemented, not yet checked by hand.** Driven by a temporary in-app self-test (100k-file folder timings,
browsing an SMB share read-only, hidden extensions and rename, Tab / F6 focus order with real key events, VoiceOver
attributes, onboarding and Settings snapshots in light and dark), plus a dry-run release (ad-hoc signed DMG, appcast
item whose EdDSA signature verifies against the app's public key, bundled app launching with Sparkle).
Not exercised: notarization (needs a Developer ID certificate and a notarytool profile), an actual Sparkle update
(needs a published appcast; the repository is private, so the feed URL isn't reachable yet), launch at login and
the crash prompt (bundled builds only), and VoiceOver itself.
- Performance (100,000 files, release build): opening the folder blocks the main thread for ~55 ms (was ~3 s); a
  live refresh ~70 ms (was ~16 s). Sort by name 0.8 s, by type 0.9 s (was 55 s), select all 0.25 s (was 3 s),
  type-ahead 20 ms. Fixes: sort keys computed once per item instead of per comparison (type names came from
  LaunchServices on every comparison), cached type names and "known extension" lookups, item URLs standardized
  once per folder rather than per item (`standardizedFileURL` touches the file system, ~10 µs each), a cached
  selection for menu validation, and listings of 5,000+ items sorted and grouped off the main thread (also when
  only the sort order changes; layout and grouping changes still rebuild at once, ~0.6–0.8 s at 100k). Memory
  returns to baseline after leaving a big folder. `ListPerformanceTests` (opt-in) guards the sort costs.
  An SMB share (650 items) browses without file-system work on the main thread worth mentioning; scrolling is
  bounded by AppKit layout. Per-file icons are still read from the volume (no type-only icons for slow drives).
- Settings is now three tabs: General (keyboard scheme, start location, start at sign-in via `SMAppService`,
  default file browser), View (theme, accent, caption buttons, compact view, file name extensions, hidden items,
  drive letters) and Privacy & Updates (Full Disk Access status, automatic checks / downloads, beta updates,
  crash reports).
- File name extensions (View › Show, ⋯, Settings): off by default, as on Windows. Known extensions are hidden from
  names everywhere (lists, Details pane, type-ahead); unknown ones ("notes.v2") stay. Renaming edits the name
  without the extension and keeps it; an empty name is refused rather than becoming ".txt".
- Full Disk Access: shown once at first launch when access is off (`FullDiskAccess` probes TCC-protected files;
  no API exists), and from Help, Settings and a "Set Up Full Disk Access…" button wherever macOS refuses a folder
  (EPERM; plain EACCES shows Windows' "You don't currently have permission to access this folder"). Opens the
  Privacy pane, offers the app icon to drag into the list, and notices when access is turned on.
- Accessibility: icon/tile items are single VoiceOver elements (name, type as role, details as value, selected
  state), capacity bars and the Properties ring are level indicators, the speed graph reads progress and speed,
  check boxes and breadcrumb chevrons are labelled. Tab / Shift+Tab and F6 / Shift+F6 (Go menu) move between the
  address bar (which switches to the editable path), search box, navigation pane and file list; command bar and
  status bar buttons join the Tab loop with Full Keyboard Access. The address bar returns to breadcrumbs whenever
  focus leaves it.
- Updates: Sparkle 2.10 (SwiftPM; `bundle.sh` embeds and signs the framework). The EdDSA private key is in the
  login keychain (back it up: `generate_keys -x file`); the public key is `scripts/sparkle-public-key.txt`. Feed:
  `appcast.xml` on the main branch (`SU_FEED_URL` to change), DMGs as GitHub release assets. Betas are items on the
  "beta" channel (versions containing "beta"), offered with Settings › "Get beta updates". App › Check for
  Updates…. `scripts/release.sh` runs bundle → notarize → DMG → notarize → sign → appcast, and with `PUBLISH=1`
  creates the GitHub release and pushes the appcast.
- Crash reports: no SDK or server. At launch, a new macOS crash report for Explorer (`~/Library/Logs/
  DiagnosticReports`) prompts "Report…", which opens a prefilled GitHub issue (versions, exception, crashed
  thread; no paths) for the user to review. Help › Report a Problem… opens a blank issue with versions filled in.
- Bundle ID is now `co.justgeeks.explorer` (settings of earlier ad-hoc bundles stay under the old ID). The app is
  named **Panes** (`APP_NAME`; UI text uses `AppInfo.name`; "OSX Explorer" was dropped: OS X is Apple's
  trademark); DMGs are `Panes-<version>.dmg` (`dmg.sh` turns spaces into hyphens, which GitHub would otherwise
  rename).
- Settings › View › "Classic context menu (Windows 10 style)": every item command at once (open commands, Quick
  access, Share, Compress, Send to, Cut / Copy, Delete / Rename, Copy as path, Properties) instead of the icon row
  and "Show more options". Shift+right-click shows it either way, as on Windows 11. Background menus are the same
  in both styles.
- Fixed on the way: Tab in the address bar left it editing; clicking elsewhere now ends editing too.

## Windows 98 style
Settings › View › Style: **Windows 11** (default) or **Windows 98**, switched live. A reskin of the same layout,
not Windows 98 Explorer's layout.
- Colours from Windows 98's "Windows Standard" scheme: grey `#C0C0C0` face, 3D edges (raised buttons, sunken
  lists and text boxes, etched separators), white lists, navy `#000080` selection with white text (grey when the
  list isn't focused). Always light; the Theme and Accent settings are disabled while it's on.
- MS Sans Serif (macOS ships its TrueType version) at 11 pt, Tahoma Bold for bold; tighter rows (18 pt Details).
- The tab strip is the title bar's navy-to-blue gradient (greys when the window is inactive), with property-sheet
  tabs standing on the face; "Window buttons on the right" gives 16 × 14 pt raised caption buttons. Command and
  address bar buttons are flat toolbar buttons that rise under the mouse and sink when pressed. Details' column
  headers are raised buttons. Icon views highlight only the name. Drive capacity bars are Windows 98 progress
  bars (blocks). The status bar text sits in a sunken panel.
- Not restyled: menus and context menus, dialogs (Properties, Settings, progress, conflicts, wizards), scroll
  bars, and the icons (SF Symbols and macOS file icons).
- `Theme.isClassic` is read from the defaults so colour providers can resolve it off the main actor; colours pick
  the style when drawn, and views that cache fonts or sizes adopt `StyleObserving` (`Theme.restyle(_:)` walks
  every tab's views after a switch). Checked with window snapshots in both styles, light and dark, switching
  back and forth; the Windows 11 render is unchanged.

## Cloud storage (~5–6 weeks)
OneDrive, iCloud Drive, Dropbox, Google Drive, Box and any other File Provider sync client, shown as Windows shows
OneDrive: a root in the navigation pane, a Status column, "Always keep on this device" / "Free up space".

**Approach:** build on the providers' own sync clients, not their web APIs. Each client already syncs to a real
folder (`~/Library/CloudStorage/<Provider>-<Account>`; iCloud Drive at `~/Library/Mobile Documents/com~apple~CloudDocs`),
so the loader, watcher and operation engine work there unchanged. The work is recognising those folders, showing
their sync state, and never downloading files by accident. No sign-in, no app registrations, one code path for every
provider; per-provider code is limited to names and icons. Sharing, View online, Version history and pinning come
from the providers' own File Provider actions (Stage 4); web APIs (Microsoft Graph) are only an optional later
stage, for Home.

**Already in the way:**
- `FileSearch.isSearchable` and `isUserFile` leave out everything under `~/Library/`, which holds both
  `CloudStorage` and `Mobile Documents`: cloud files never appear in search results or Recent.
- Thumbnails (`ThumbnailProvider`), `FilePropertiesReader` (dimensions, duration) and the `ContentTotals` walk can
  make a provider download online-only files; Large icons on a big cloud folder could pull gigabytes.
- `ExplorerLocation.parent` / `ancestry` would show "Macintosh HD › Users › … › CloudStorage › OneDrive-Personal".
- Free to fix: `BulkDirectoryReader` already reads `ATTR_CMN_FLAGS`, which carries `SF_DATALESS` (online-only).

### Stage 0 — Spike (done 2026-10-25, OneDrive for Business on macOS 15.7)
1. **Download / Free up space work** from an unsandboxed app: `startDownloadingUbiquitousItem` downloaded a
   9 KB file in ~1 s, `evictUbiquitousItem` made it online-only again.
2. **Status keys are filled in:** `isUbiquitousItem` (true for the root and everything in it), downloading
   status (`notDownloaded` / `current`), is uploaded / uploading / downloading, conflicts, errors. Reading them costs
   ~1 ms per item (100 items: 80–120 ms), so never for a whole big folder on the main thread. `SF_DATALESS` matches
   "not downloaded" for files and costs nothing (already in the bulk read). A folder reports `current` once its
   listing has been fetched, even if everything in it is online-only: a folder's own status says nothing about its
   contents.
3. **Pinning can't be done or seen by other apps.** OneDrive's "Always Keep on This Device" is its own File Provider
   action (`com.microsoft.OneDrive.FileProviderActions.MarkPinned`), shown only in Finder's menu; a pinned item has
   content policy 3 (download eagerly, keep downloaded) and a "Pinned" decoration, neither exposed to clients
   (`fileproviderctl evaluate` shows them). Setting macOS 15's `com.apple.fileprovider.pinned#PX` xattr does nothing
   for OneDrive. So: "Download now" and "Free up space", no pinned state. *Superseded by Stage 4's spike: the action
   and both values are reachable through private FileProvider.framework classes, as Finder reaches them.*
4. **Thumbnails are safe:** `QLThumbnailGenerator` on an online-only file asks the provider for a thumbnail
   ("Could not download a thumbnail for cloud item" for an .xlsx) and doesn't download the file.
5. **`displayName(atPath:)` gives the raw folder name** ("OneDrive-JustGeeks"), so the naming table is needed. The
   root's `com.apple.file-provider-domain-id` xattr holds the provider and its own name
   (`com.microsoft.OneDrive-mac.FileProvider/OneDrive - JustGeeks`).
6. **Spotlight indexes OneDrive**, online-only files included: search can keep using it.
- Listing a folder (even `ls -R`) makes the provider fetch listings from the network, without downloading files:
  recursive walks (folder sizes, walked searches) are slow in cloud folders but don't fill the disk.
- `FilePropertiesReader` falls back to reading image headers, which downloads online-only pictures: guard it.
  Quick Look previews (preview pane) download the file, as on Windows.

### Stage 1 — Navigation (~1–1.5 weeks)
- [x] `CloudStorage` (ExplorerCore): lists the cloud roots under an injectable base folder. Provider table maps
      folder names to titles and icons: `OneDrive-Personal` → "OneDrive - Personal", `OneDrive-<Org>` →
      "OneDrive - <Org>", `OneDrive-SharedLibraries-<Org>` → "<Org>" (SharePoint, its own root as on Windows),
      `GoogleDrive-<email>` → "Google Drive (<email>)", `Dropbox` → "Dropbox", `Box-Box` → "Box", iCloud Drive →
      "iCloud Drive". Unknown providers fall back to `displayName(atPath:)` and a generic cloud icon.
- [x] Navigation pane: one root per cloud folder between Home and the pins (Windows 11's order); `CloudCenter`
      watches `CloudStorage` (and re-reads on activation, for iCloud Drive) so roots come and go when accounts are
      added or removed. Pin reordering skips them.
- [ ] Cloud roots expandable into their folders (needs the pane to become a real tree, listed off the main thread:
      a cloud folder's first listing can wait on the network).
- [x] `ExplorerLocation`: a cloud root is the top of its hierarchy (parent `.home`, its display name), so the
      breadcrumb reads "Home › OneDrive - Personal › Documents"; Home's chevron lists the cloud folders; the
      editable path stays the real one.
- [x] Search and Recent: cloud folders inside `~/Library/` are no longer left out.
- [x] Cloud roots can be pinned to Quick access (with their cloud title and icon).

**Status:** checked in the app with this Mac's iCloud Drive (navigation pane, breadcrumb, Home's chevron; no
errors in the log). No File Provider client is installed, so `CloudStorage` roots, and `CloudCenter` noticing a new
account, are covered only by unit tests (fake `CloudStorage` folder).

### Stage 2 — Sync status (~1.5 weeks)
- [x] `CloudStatus` on `FileItem`: available on this device, available when online, sync pending, sync problem
      (no "always available": providers don't expose pinning, see the spike). `FileItem.isOnlineOnly` comes from
      `SF_DATALESS` in the bulk read; in a cloud folder (a cloud path, or `isUbiquitousItem`: Desktop and Documents
      in iCloud) `DirectoryLoader` gives files their status from that alone. The tab then asks the File Provider
      (~1 ms each, off the main thread) only about items with local contents, the only ones that can be syncing, and
      reloads every 3 s while any are (finished uploads don't touch the folder, so FSEvents is silent). Folders show
      only syncing and problems: their own state says nothing about their contents. Search results and Home get the
      listing's status (`FileItem.load`).
- [x] `FileColumn.status`: icons only, as on Windows (blue cloud, green check, blue arrows, red cross) with the
      wording as tooltip and VoiceOver label; Status follows Name by default in cloud folders, sortable. A badge on
      the icon's corner in icon, Tiles and Content views (icons of 32 pt and up). Same SF Symbols in the Windows 98
      style, which doesn't restyle icons.
- [x] No accidental downloads: `FilePropertiesReader` doesn't read online-only pictures' headers. Thumbnails need no
      guard (the spike). Checked on OneDrive: Details and Large icons over 62 online-only files downloaded none,
      and OneDrive's own thumbnails (videos, PDFs, documents) show.
- [x] Size on disk 0 for online-only files in Properties: already so (`totalFileAllocatedSize` is 0 for them).
- [ ] Not seen yet: the syncing and problem glyphs (needs a file uploading into OneDrive).

### Stage 3 — Commands (~1 week)
- [x] "Download now" and "Free up space" (`CloudSync`) in both context menus, the command bar's ⋯ and File menu,
      shown for items in cloud folders only. No "Always keep on this device": the spike found no way for another app
      to set or read OneDrive's pin. Download now is a file operation (`.download`): it asks for every online-only
      file (inside folders too) at once, then waits on each, with the progress dialog; the items show as syncing
      meanwhile. Free up space evicts each item (a folder: everything in it) off the main thread.
- [x] Properties › General: Status (glyph and wording) for files, and folders while syncing.
- [x] Opening or copying an online-only file downloads it first: opening runs `.download` before the app is
      launched; a copy downloads each online-only source before `copyfile`, polling `SF_DATALESS` every 0.1 s. The
      dialog says "Downloading from <provider>…" and holds speed and time remaining meanwhile; cancel evicts the file,
      which stops the download.
- [x] Deleting from a cloud folder: "Deleted files are removed everywhere", naming the provider, until "Don't show
      this again"; the permanent-delete confirmation says so too.
- [x] Online-only items (and folders holding any) are deleted outright, not moved to the Trash: `trashItem` on an
      online-only OneDrive file failed at once from a command-line tool and never returned in the app (20 s+, the
      File Provider holding it). So `.trash` deletes them (`CloudSync.hasOnlineOnlyContents`, cloud items only,
      without listing online-only folders), as Windows sends them to the online recycle bin; no undo for them. The
      warning then always shows, without "Don't show this again", saying they can't be restored from the Recycle
      Bin. Downloaded files still go to the Trash as a full local copy.

**Status:** checked in the app on OneDrive for Business: Download now / Free up space on an online-only file
(syncing glyph while downloading, then on this device; online-only again after), Properties for both states, the
delete warning (cancelled), and copying a 104 MB online-only video out of OneDrive, cancelled mid-download: no
partial copy, the video online-only again. Deleting: a downloaded file went to the Trash as a full copy; an
online-only one was deleted in 0.35 s after the warning. Engine behaviour is unit-tested against a fake sync client.

### Stage 4 — Provider actions (~1.5–2 weeks)
Share, Copy link, View online, Version history and "Always keep on this device" as Finder does them: by running the
provider's own File Provider actions. No Graph, no sign-in, no app registration, and it works for every provider that
declares actions, each in its own wording.

**Spike (2026-10-26, OneDrive for Business, macOS 15.7, unsandboxed command-line tool):**
1. **Finder doesn't implement these.** The provider's extension declares them in its `Info.plist`
   (`NSExtensionFileProviderActions`: identifier, localized-name key, `NSPredicate` activation rule). OneDrive's:
   `MarkPinned` "Always Keep on This Device", `MarkUnpinned` "Free Up Space", `ShareLink` "Share", `CopyLink` "Copy
   Link", `ViewOnline`, `VersionHistory`, `CheckOut` / `CheckIn`, `AskCopilot`, `Unmount` "Remove Shortcut",
   `PrioritizeSync`, `Reactivate`, plus two debug actions (hidden by their rules). Names live in the extension's
   `Localizable.strings`.
2. **Finder runs them through private FileProvider.framework classes, and so can we:**
   `FPItemManager.defaultManager` → `itemForURL:error:` (an `FPItem`) → `FPVendorDefinedActionOperation`
   `initWithActionIdentifier:providerDomainID:itemIdentifiers:` (the item's `providerDomainID` and `itemIdentifier`),
   `setActionCompletionBlock:`, `FPItemManager addOperation:`. Completes at once, without an error; the provider does
   the work afterwards. `eligibleActionsForItems:` lists only system actions (Copy, Move, Rename…), not vendor ones.
3. **The activation rules can be evaluated ourselves:** `FPItem.userInfo` carries the provider's flags (`showShare`,
   `showViewOnline`, `showVersionHistory`, `showPinUnpin`, `showCheckOut`…), the same ones Finder's menu uses.
4. **Results:** Copy link put a `https://<tenant>-my.sharepoint.com/:t:/g/personal/…` link on the clipboard ~4 s
   after the call (the org's default link type, as in Finder). Share opened OneDrive's share window. Pinning an
   online-only file downloaded it at once: content policy 1 → 3 and OneDrive's `Pinned` decoration. While pinned,
   `evictUbiquitousItem` fails (`NSFileProviderErrorDomain` -2008, "cannot be evicted").
5. **Pinned state is readable:** `FPItem.decorations` (`…FileProviderBadges.Pinned` / `.Syncing` / `.Shared`) and
   `contentPolicy`; `itemForURL:` costs ~1 ms per item (99 items: 78–106 ms), like the public status keys. Prefer the
   decoration: folders report content policy 3 without being pinned.
6. **The provider's extension is found from the domain:** `FPProviderDomain providerDomainForURL:error:` →
   `extensionBundleURL`, `localizedName` ("OneDrive").
  View online opened the file in the browser.
- **Unpinning sticks, in Finder too (OneDrive 26.168.0830):** after `MarkUnpinned` the item shows `Syncing`, keeps
  policy 3 and still can't be evicted, for minutes, until OneDrive is restarted. Finder's "Free Up Space" on a
  cleanly pinned file does the same, so it's OneDrive's bug, not our call: we behave as Finder does.
- Not identified: the OneDrive window Version history opened. Not tried: several items at once (`itemIdentifiers`
  takes an array), Check out / in, other providers.

**Tasks:**
- [x] `FileProviderBridge`, a small Objective-C target: the private classes looked up by name, every method
      checked before use, ARC knowing the alloc/init and out-parameter semantics, and no Objective-C exception let
      through (a provider's malformed rule would otherwise crash `NSPredicate`). Missing classes → no provider
      actions, never a crash.
- [x] `ProviderActions` (ExplorerCore): a domain's declared actions and names from its extension bundle (cached per
      extension; debug actions left out), each rule evaluated against the real items (`fileproviderItems`) and the
      domain's `domainUserInfo`, as Finder does; `perform` runs one on the selection. A role (pin / unpin / other)
      told from the identifier. Unit-tested with OneDrive's declarations, a fake extension bundle and fake items.
- [x] Menus: both context menus, the command bar's ⋯ and the File menu (rebuilt in `menuWillOpen`, not
      `menuNeedsUpdate`, which also runs for key equivalents) list the selection's eligible actions after Download
      now / Free up space, in the provider's order and wording. Its unpin ("Free Up Space") isn't listed: our Free up
      space runs it. ~10–14 ms for one OneDrive item.
- [x] `CloudStatus.alwaysAvailable` (solid green check) from content policy 3 or a `Pinned` badge, and the provider's
      `Syncing` badge counted as syncing (so a stuck unpin shows as Finder shows it), read in Stage 2's off-main pass:
      one more ~1 ms lookup per item with local contents.
- [x] Free up space on a pinned item: eviction fails as `nonEvictable`, so the provider's unpin runs instead.
- [x] Download now / Free up space stay ours, also for providers that declare no actions (iCloud Drive).
- [ ] Not done, on purpose: "Always keep on this device" as a checked toggle (OneDrive's rule offers pin whatever the
      state, as Finder does; the Status column shows it), and Share in Windows 11's icon row (still the macOS share
      sheet) running the provider's Share.

**Status:** checked in the app on OneDrive for Business with a temporary self-test hook (removed): the menu items
(Always Keep on This Device, Share, Copy Link, Version History, View Online), the File menu's, Copy link putting a
SharePoint link on the clipboard, pinning a file (status → always available), Free up space on it running
OneDrive's unpin without an error (status → syncing, OneDrive's bug), no errors in the log.

### Stage 5 — Optional: Microsoft Graph for Home (separate decision)
Only Home's "Shared with me" / "Recommended" still need a web API. Graph's `drive/sharedWithMe` and `drive/recent`
are deprecated and stop returning data in November 2026, so it would be the Search API or `/me/insights`
(`shared`, `used`). Needs an Entra ID app registration (multi-tenant needs publisher verification), OAuth PKCE via
`ASWebAuthenticationSession` (or MSAL, for Conditional Access device compliance), and tokens in the keychain. Other
providers' APIs are out of scope.

**Tests:** unit tests for root discovery and naming (fake `CloudStorage` tree), flags/keys → `CloudStatus`,
`parent` / `ancestry` of cloud roots, `isSearchable` / `isUserFile` with cloud paths, sorting by status; the
env-gated self-test for the Status column and menu items. By hand, per installed provider: browse 1,000+ online-only
files in Large icons without downloads, Free up space / Keep, copy in and out, cancel mid-download.

## Remote folders (SSH)
Browse folders on any computer you can `ssh` to, and copy files in and out, like a mapped drive.

**Approach:** the system's `/usr/bin/ssh`, so `~/.ssh/config`, keys, the agent, `ProxyJump` and `known_hosts` all work
as in Terminal; no new dependency, no sshfs/macFUSE. One master connection per server (`ControlMaster`, sockets in
`$TMPDIR/panes-ssh`, `ControlPersist=300`); the app speaks SFTP v3 itself over `ssh -s host sftp` channels through
it (`SFTPClient`). `scp` can't list folders and has used SFTP underneath since OpenSSH 9.0, so this is the same
protocol, with exact sizes, dates and types, error codes rather than text, and byte-exact progress.

**Status: implemented** (stages 1–4), checked against a real sshd in an in-app self-test.
- Entry points: the address bar (`user@host:/path`, `host:`, `sftp://user@host:port/path`, `ssh://`, `scp://`; a
  local folder of the same name wins), Connect to SSH Server… (File menu, ⋯, Network's menus; Server, User name,
  Port, Folder, "Remember this server under Network"), Network's page and the navigation pane (saved servers, then
  `~/.ssh/config` hosts without wildcards, following `Include`). The breadcrumb reads Network › server › folders;
  Up from `/` goes to Network.
- Sign-in: ssh runs the app's own executable as `SSH_ASKPASS` (`SSH_ASKPASS_REQUIRE=force`); it hands the question to
  the running app over a Unix socket with a per-launch token, and the app asks as a sheet on the window that wanted
  to connect: unknown host key (Connect / Cancel), password ("incorrect, try again" the second time), key
  passphrase, agent confirmation. Cancelling shows "Sign-in was cancelled" with Connect. A changed host key is
  refused with ssh's advice (`ssh-keygen -R`). Passwords aren't saved; `UseKeychain` / `AddKeysToAgent` work for keys.
- In a remote folder: open (downloads to `~/Library/Caches/<bundle>/Remote Files`, reused while size and date match,
  then opens the copy; a one-time notice says edits stay in the copy), Open with, open in new tab/window, Copy then
  Paste in a local folder (download), Paste or drop local files (upload, always a copy), Download to…, Upload files…,
  drag out to Finder (file promises), Copy as path (`user@host:/path`), Disconnect, Filter, views and sorting.
  Properties, Share, Compress, Terminal, Cut, New text document and search are off. No live updates: F5 refreshes.
- Delete, Rename and New folder work on the server (`.remoteDelete`, `.remoteRename`, `.remoteCreateFolder`).
  Delete is permanent after a confirmation, as Windows does for network folders: folders are emptied first, links
  are deleted rather than followed, and a folder whose contents were partly skipped stays. Rename is in place (F2)
  and can be undone; names may contain a colon; changing only the case goes through a temporary name, so it works on
  case-insensitive servers. New folder makes "New folder", "New folder (2)"… and starts renaming it; it can't be
  undone (undoing would have to delete whatever was put in it since).
- Transfers run in the operation engine (`.remoteDownload`, `.remoteUpload`), with the progress window, pause,
  cancel and Replace / Skip / Keep both. Files arrive under a temporary name (`.name.panes-part`,
  `.name.panes-upload-…`) and are renamed into place, so a cancelled transfer leaves nothing behind. Dates and
  permissions are kept. Downloads can be undone (moved to the Recycle Bin); uploads can't.
- Hidden files follow Show hidden items (names starting with "."). Links are followed: a link to a folder is a
  folder. Thumbnails, Quick Look previews and Spotlight properties are off for remote items; icons come from the type.

**Later:** servers without an SFTP subsystem (some BusyBox/Dropbear) get "The server doesn't offer file transfer";
a shell-based fallback could list with `sh` and copy with `cat`. Also: moving within a server, uploading a saved edit of an opened copy, Open in Terminal (`ssh -t`), passwords in the keychain, copying between
two servers. ssh shortens key paths in its passphrase prompt to 100 characters, so very long key paths show cut off.

**Tests:** `RemotePathTests` (address forms, IPv6, percent-encoding round trips, rejecting `-oProxyCommand=…` and
`C:`), `SSHConfigTests`, `SSHCommandTests` (arguments, socket path length, classifying ssh's errors), `AskpassTests`
(real OpenSSH prompts, token check), and `SFTPTests`, which run the real `/usr/libexec/sftp-server` over pipes:
listing, links, errors, downloads and uploads with conflicts, cancelling mid-file; `SFTPEditTests` for delete
(links, skipped contents), rename (undo, taken and invalid names, case only) and new folder. Against a real server:
`EXPLORER_SSH_TESTS=1 [EXPLORER_SSH_HOST=host] [EXPLORER_SSH_CONFIG=file] scripts/test.sh` (sign-in, master reuse,
a transfer round trip, reconnecting). `EXPLORER_SSH_CONFIG` also makes the app use that file instead of
`~/.ssh/config`, e.g. for a private `sshd -f config` on a high port.

---

## Risks
1. **Finder cannot be fully replaced** — macOS still uses Finder for the Desktop, "Show in Finder" from other apps, and the Trash. Aim to be the best "open folder" target, not a full replacement.
2. **TCC / Full Disk Access** — without it, Mail, Safari data, other users' folders etc. are blocked; onboarding must handle this gracefully.
3. **Trademarks** — don't use "Windows" or Microsoft logos in the app name/icon. Fluent System Icons are fine; Segoe and Windows shell icons are not.
4. **File operations on network / external volumes** — SMB/exFAT quirks (no xattrs, case-insensitivity, partial copies). Budget extra testing time for the operation engine.
5. **Cloud providers** — pinning, sharing and the other provider actions have no public client API: they go through
   private FileProvider.framework classes, as Finder's menu does (Stage 4), which a macOS update could change or
   lock down; they must disappear quietly, leaving Download now / Free up space. Per-item sync status is a daemon
   call (~1 ms), so it's only read for items with local contents; provider names (OneDrive, Dropbox…) are used
   descriptively only, never their logos.

**Rough total:** 18–22 weeks for one experienced macOS developer. Usable MVP (Phases 0–2 + Details view + tabs) in ~7–8 weeks.
