import AppKit
import ExplorerCore

/// One Explorer window: the title-bar tab strip over the selected tab's view, on a
/// Mica-style translucent background. Window-level commands (tabs, undo) live here; every
/// other command is forwarded to the selected tab, which is also in the responder chain
/// whenever it has focus.
///
/// There is no `NSToolbar`: a toolbar would swallow clicks in the title bar, so the tab strip
/// sits in the content view under the transparent title bar, and the traffic lights are moved
/// down to line up with it.
@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "ExplorerWindow"

    private(set) var tabs: [ExplorerTabController] = []
    private(set) var selectedIndex = 0
    var onClose: (() -> Void)?

    private let tabStrip = TabStripView()
    private let tabContainer = NSView()
    /// The selected tab, and in dual-pane mode the second pane beside it.
    private let paneSplit = NSSplitView()
    private let primaryPane = NSView()
    /// Dual-pane mode's second pane: a tab of its own that isn't in the tab strip.
    private(set) var companion: ExplorerTabController?
    /// Undo for text being edited (rename, address bar), kept apart from file operations.
    private let textUndoManager = UndoManager()
    private var observers: [NSObjectProtocol] = []
    /// The Mica-style background; hidden in Windows 98 style.
    private let mica = NSVisualEffectView()
    /// The style the views were last laid out for.
    private var appliedStyle: AppSettings.VisualStyle?

    var selectedTab: ExplorerTabController? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    /// A window with one tab at `location`.
    convenience init(location: ExplorerLocation) {
        self.init(tabs: [ExplorerTabController(location: location)])
    }

    /// A window holding `tabs` (e.g. one dragged out of another window), optionally at `frame`.
    init(tabs: [ExplorerTabController], frame: NSRect? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 360)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: window)

        window.contentView = makeContentView()
        if let frame {
            window.setFrame(frame, display: false)
        } else if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        } else {
            // Cascade new windows off the remembered frame.
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(
                x: window.frame.minX,
                y: window.frame.maxY
            )))
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.delegate = self
        tabStrip.delegate = self

        for tab in tabs { attach(tab) }
        self.tabs = tabs
        select(0)

        observers.append(AppSettings.observe { [weak self] in self?.applySettings() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The translucent layer sits *behind* the content as a sibling: views inside an
    /// `NSVisualEffectView` draw with vibrancy, which washes text out against a dark background.
    private func makeContentView() -> NSView {
        mica.material = .underWindowBackground
        mica.blendingMode = .behindWindow
        mica.state = .followsWindowActiveState
        // On its own the material is near-black in dark mode; Windows' Mica is a dark grey.
        let micaTint = LayerView(color: Theme.micaTintColor)

        // Layer-backed throughout, so views that draw themselves stack above the effect view's
        // layer instead of painting into the base layer underneath it.
        let background = NSView()
        background.wantsLayer = true
        for subview in [mica, micaTint, tabStrip, tabContainer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            mica.topAnchor.constraint(equalTo: background.topAnchor),
            mica.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            mica.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            mica.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            micaTint.topAnchor.constraint(equalTo: background.topAnchor),
            micaTint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            micaTint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            micaTint.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            tabStrip.topAnchor.constraint(equalTo: background.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: Theme.tabStripHeight),

            tabContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            tabContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tabContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.addArrangedSubview(primaryPane)
        Self.fill(tabContainer, with: paneSplit)
        return background
    }

    private static func fill(_ container: NSView, with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Settings

    private func applySettings() {
        Theme.applyAppearance()
        applyStyle()
        let windowsButtons = AppSettings.windowsCaptionButtons
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = windowsButtons
        }
        tabStrip.showsCaptionButtons = windowsButtons
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        tabStrip.leadingInset = windowsButtons || fullScreen ? 8 : 78
        updateTabStrip()
        positionTrafficLights()
        setDualPane(AppSettings.dualPane)
    }

    /// Windows 11 or Windows 98: after a switch, every tab (shown or not) picks up the new
    /// fonts and metrics and redraws.
    private func applyStyle() {
        let style = AppSettings.visualStyle
        mica.isHidden = style == .classic
        guard style != appliedStyle else { return }
        let isFirst = appliedStyle == nil
        appliedStyle = style
        guard !isFirst, let contentView = window?.contentView else { return }
        Theme.restyle(contentView)
        for tab in tabs where tab.view.superview == nil { Theme.restyle(tab.view) }
    }

    // MARK: Dual pane

    /// Shows or hides the second pane. It starts where new tabs start, and is forgotten when
    /// hidden.
    private func setDualPane(_ enabled: Bool) {
        guard enabled != (companion != nil) else { return }
        if enabled {
            let pane = ExplorerTabController(location: AppDelegate.newTabLocation)
            pane.rootViewController.isCompanion = true
            pane.host = self
            companion = pane
            paneSplit.addArrangedSubview(pane.view)
            paneSplit.layoutSubtreeIfNeeded()
            paneSplit.setPosition(paneSplit.bounds.width / 2, ofDividerAt: 0)
        } else if let pane = companion {
            let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
            companion = nil
            pane.view.removeFromSuperview()
            pane.close()
            if hadFocus { selectedTab?.focusContent() }
        }
    }

    /// Centres the traffic lights on the tab strip, which is taller than the title bar, and
    /// keeps the title bar see-through. (Even with `titlebarAppearsTransparent`, AppKit leaves
    /// a blur view in the title bar that smudges and darkens the tabs beneath it.)
    private func positionTrafficLights() {
        if let titlebar = window?.standardWindowButton(.closeButton)?.superview {
            for case let blur as NSVisualEffectView in titlebar.subviews where blur.alphaValue != 0 {
                blur.alphaValue = 0
            }
        }
        guard let window, !AppSettings.windowsCaptionButtons, !window.styleMask.contains(.fullScreen) else { return }
        let centerFromTop = Theme.tabStripHeight / 2 + 1
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let superview = button.superview else { continue }
            let center = superview.convert(NSPoint(x: 0, y: window.frame.height - centerFromTop), from: nil)
            let origin = NSPoint(x: 13 + CGFloat(index) * 20, y: center.y - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    func windowDidResize(_ notification: Notification) {
        positionTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        applySettings()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applySettings()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        positionTrafficLights()
        tabStrip.needsDisplay = true // Windows 98's title bar greys out when inactive
    }

    func windowDidResignKey(_ notification: Notification) {
        positionTrafficLights()
        tabStrip.needsDisplay = true
    }

    // MARK: Tabs

    private func attach(_ tab: ExplorerTabController) {
        tab.host = self
    }

    private func updateTabStrip() {
        tabStrip.setTabs(
            tabs.map { TabStripView.Tab(title: $0.title ?? "", icon: $0.icon) },
            selectedIndex: selectedIndex
        )
        window?.title = selectedTab?.title ?? ""
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let previous = selectedTab
        selectedIndex = index
        let tab = tabs[index]
        if previous !== tab || tab.view.superview !== primaryPane {
            previous?.view.removeFromSuperview()
            Self.fill(primaryPane, with: tab.view)
            tab.focusContent()
        }
        updateTabStrip()
    }

    /// Adds `tab` at `index` (default: after the selected tab).
    func insert(_ tab: ExplorerTabController, at index: Int? = nil, select shouldSelect: Bool = true) {
        let position = min(index ?? selectedIndex + 1, tabs.count)
        attach(tab)
        tabs.insert(tab, at: position)
        if position <= selectedIndex, tabs.count > 1, !shouldSelect {
            selectedIndex += 1
        }
        if shouldSelect {
            select(position)
        } else {
            updateTabStrip()
        }
    }

    /// Takes `tab` out of this window without closing it (it's moving to another window).
    /// Closes the window if it was the last tab.
    func remove(_ tab: ExplorerTabController) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = index == selectedIndex
        let next = TabStripLayout.selectionAfterClosing(index, selected: selectedIndex, count: tabs.count)
        tabs.remove(at: index)
        tab.view.removeFromSuperview()
        tab.host = nil
        guard let next else {
            window?.close()
            return
        }
        selectedIndex = next
        if wasSelected {
            select(next)
        } else {
            updateTabStrip()
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        remove(tab)
        tab.close()
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        selectedIndex = TabStripLayout.indexAfterMove(selectedIndex, from: from, to: to)
        updateTabStrip()
    }

    /// Opens the tab at `index` in a new window, with its top-left corner at `screenPoint`.
    func detachTab(at index: Int, to screenPoint: NSPoint? = nil) {
        guard tabs.count > 1, tabs.indices.contains(index), let window else { return }
        let tab = tabs[index]
        remove(tab)
        var frame = window.frame
        if let screenPoint {
            frame.origin = NSPoint(x: screenPoint.x - 80, y: screenPoint.y - frame.height + 16)
        } else {
            frame.origin.x += 30
            frame.origin.y -= 30
        }
        AppDelegate.shared.openWindow(with: tab, frame: frame)
    }

    // MARK: Commands

    @objc func newTab(_ sender: Any?) {
        insert(ExplorerTabController(location: AppDelegate.newTabLocation))
    }

    @objc func closeTab(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let index = item.representedObject as? Int {
            closeTab(at: index)
        } else {
            closeTab(at: selectedIndex)
        }
    }

    @objc func closeOtherTabs(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        for tab in tabs where tab !== keep {
            closeTab(at: tabs.firstIndex { $0 === tab } ?? 0)
        }
    }

    @objc func closeTabsToTheRight(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        while tabs.count > index + 1 {
            closeTab(at: tabs.count - 1)
        }
    }

    @objc func showNextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((selectedIndex + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        select((selectedIndex - 1 + tabs.count) % tabs.count)
    }

    /// Ctrl+1…8 select that tab; Ctrl+9 the last one, as in browsers.
    @objc func showTabAtIndex(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        select(index)
    }

    @objc func duplicateTab(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.representedObject as? Int ?? selectedIndex
        guard tabs.indices.contains(index) else { return }
        insert(ExplorerTabController(location: tabs[index].history.current), at: index + 1)
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.representedObject as? Int ?? selectedIndex
        detachTab(at: index)
    }

    /// Commands this window doesn't handle go to the selected tab, even when focus is
    /// outside it (in the tab strip, or nowhere).
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let tab = selectedTab, tab.responds(to: action) {
            return tab
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : FileOperationCenter.shared.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs { tab.close() }
        tabs = []
        companion?.close()
        companion = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onClose?()
    }
}

// MARK: - Tab hosting

extension ExplorerWindowController: TabHosting {
    func tabDidChangeTitle(_ tab: ExplorerTabController) {
        guard tab !== companion else { return }
        updateTabStrip()
    }

    func otherPane(of tab: ExplorerTabController) -> ExplorerTabController? {
        guard let companion else { return nil }
        return tab === companion ? selectedTab : companion
    }

    func openTab(at location: ExplorerLocation, besides tab: ExplorerTabController, select: Bool) {
        let index = tabs.firstIndex { $0 === tab } ?? selectedIndex
        // Background tabs opened from the same tab line up after each other, as in browsers.
        insert(ExplorerTabController(location: location), at: index + 1, select: select)
    }
}

// MARK: - Tab strip

extension ExplorerWindowController: TabStripDelegate {
    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int) {
        select(index)
    }

    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabStripDidRequestNewTab(_ strip: TabStripView) {
        newTab(nil)
    }

    func tabStrip(_ strip: TabStripView, moveTabFrom from: Int, to: Int) {
        moveTab(from: from, to: to)
    }

    func tabStrip(_ strip: TabStripView, canDragTabAt index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        TabDragging.tab = tabs[index]
        return true
    }

    func tabStrip(_ strip: TabStripView, acceptDraggedTabAt index: Int) {
        guard let tab = TabDragging.tab,
              let source = tab.host as? ExplorerWindowController,
              source !== self else { return }
        source.remove(tab)
        insert(tab, at: index)
        window?.makeKeyAndOrderFront(nil)
    }

    func tabStrip(_ strip: TabStripView, detachTabAt index: Int, at screenPoint: NSPoint) {
        if tabs.count > 1 {
            detachTab(at: index, to: screenPoint)
        } else if let window {
            // The only tab: move the window instead, as Windows does.
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 80, y: screenPoint.y + 16))
        }
    }

    func tabStrip(_ strip: TabStripView, menuForTabAt index: Int) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = index
            menu.addItem(item)
        }
        add("New tab", #selector(newTab(_:)))
        add("Duplicate tab", #selector(duplicateTab(_:)))
        add("Move tab to new window", #selector(moveTabToNewWindow(_:)), enabled: tabs.count > 1)
        menu.addItem(.separator())
        add("Close tab", #selector(closeTab(_:)))
        add("Close other tabs", #selector(closeOtherTabs(_:)), enabled: tabs.count > 1)
        add("Close tabs to the right", #selector(closeTabsToTheRight(_:)), enabled: index < tabs.count - 1)
        return menu
    }
}

extension ExplorerWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return tabs.count > 1
        case #selector(showTabAtIndex(_:)):
            return menuItem.tag <= tabs.count || menuItem.tag == 9
        case #selector(moveTabToNewWindow(_:)):
            return tabs.count > 1
        default:
            return true
        }
    }
}
