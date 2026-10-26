import AppKit
import ExplorerCore

/// Windows-style file-operation progress dialog: one row per running operation, each with a
/// pause and cancel button and, in "More details" mode, a speed graph.
///
/// The window appears only if an operation is still running after a short delay, so quick
/// operations never flash it.
@MainActor
final class ProgressWindowController: NSWindowController, NSWindowDelegate {
    private static let showDelay: TimeInterval = 0.6
    private static let detailsDefaultsKey = "ProgressShowsDetails"

    private var rows: [UUID: OperationProgressView] = [:]
    private let stack = NSStackView()
    private let detailsButton = NSButton()
    private var hasBeenPositioned = false
    private var showsDetails = UserDefaults.standard.object(forKey: detailsDefaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsDetails, forKey: Self.detailsDefaultsKey)
            applyDetailsMode()
        }
    }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent(in panel: NSPanel) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        detailsButton.bezelStyle = .disclosure
        detailsButton.setButtonType(.pushOnPushOff)
        detailsButton.title = ""
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        let detailsLabel = NSTextField(labelWithString: "")
        detailsLabel.tag = 1
        let detailsRow = NSStackView(views: [detailsButton, detailsLabel])
        detailsRow.spacing = 4
        detailsRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        content.addSubview(detailsRow)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 480),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detailsRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            detailsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            detailsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        applyDetailsMode()
    }

    func add(_ task: FileOperationTask) {
        let row = OperationProgressView(task: task)
        row.showsDetails = showsDetails
        rows[task.id] = row
        if !stack.arrangedSubviews.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            stack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateTitle()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rows[task.id] != nil else { return }
                self.showNow()
            }
        }
    }

    func update(_ id: UUID, progress: FileOperationProgress) {
        rows[id]?.update(progress)
        updateTitle()
    }

    func remove(_ id: UUID) {
        guard let row = rows.removeValue(forKey: id) else { return }
        // Remove the separator above the row, or below it if the row was first.
        if let index = stack.arrangedSubviews.firstIndex(of: row) {
            let neighbours = [index - 1, index + 1].filter { stack.arrangedSubviews.indices.contains($0) }
            if let separator = neighbours.map({ stack.arrangedSubviews[$0] }).first(where: { $0 is NSBox }) {
                separator.removeFromSuperview()
            }
        }
        row.removeFromSuperview()
        if rows.isEmpty {
            window?.orderOut(nil)
        } else {
            updateTitle()
            fitWindow()
        }
    }

    func summary(for id: UUID) -> String? {
        rows[id]?.summary
    }

    /// Shows the window immediately (e.g. to host an error sheet) and returns it.
    @discardableResult
    func showNow() -> NSWindow {
        // swiftlint:disable:next force_unwrapping
        let window = window!
        fitWindow()
        if !hasBeenPositioned {
            window.center()
            hasBeenPositioned = true
        }
        window.orderFront(nil)
        return window
    }

    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Grow/shrink downwards from the top edge, as Windows does.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    private func updateTitle() {
        if rows.count == 1, let row = rows.values.first {
            window?.title = row.titleText
        } else {
            window?.title = "\(rows.count) operations running"
        }
    }

    @objc private func toggleDetails() {
        showsDetails.toggle()
    }

    private func applyDetailsMode() {
        detailsButton.state = showsDetails ? .on : .off
        if let label = detailsButton.superview?.subviews.first(where: { $0.tag == 1 }) as? NSTextField {
            label.stringValue = showsDetails ? "Fewer details" : "More details"
        }
        rows.values.forEach { $0.showsDetails = showsDetails }
        if window?.isVisible == true { fitWindow() }
    }

    /// Closing the dialog cancels what it shows, as on Windows.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        rows.values.forEach { $0.task.cancel() }
        return false
    }
}

/// One operation in the progress window.
@MainActor
final class OperationProgressView: NSView {
    let task: FileOperationTask
    private(set) var progress = FileOperationProgress()
    private var meter = ThroughputMeter()

    private let summaryLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let graph = SpeedGraphView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let itemsLabel = NSTextField(labelWithString: "")
    private lazy var detailViews: [NSView] = [graph, nameLabel, timeLabel, itemsLabel]

    var showsDetails = true {
        didSet {
            detailViews.forEach { $0.isHidden = !showsDetails }
            progressBar.isHidden = showsDetails
        }
    }

    init(task: FileOperationTask) {
        self.task = task
        super.init(frame: .zero)
        build()
        update(progress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var summary: String {
        let count = progress.phase == .preparing ? task.request.sourceURLs.count : progress.totalItems
        return FileOperationText.summary(of: task.request, itemCount: count)
    }

    var titleText: String {
        let percent = "\(Int(progress.fractionCompleted * 100))% complete"
        return task.isPaused ? "Paused – \(percent)" : percent
    }

    private func build() {
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        percentLabel.font = .systemFont(ofSize: 17, weight: .regular)

        configure(pauseButton, symbol: "pause.fill", label: "Pause", action: #selector(togglePause))
        configure(cancelButton, symbol: "xmark", label: "Cancel", action: #selector(cancel))

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1

        for label in [nameLabel, timeLabel, itemsLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingMiddle
        }

        let header = NSStackView(views: [percentLabel, NSView(), pauseButton, cancelButton])
        header.spacing = 6
        let stack = NSStackView(views: [summaryLabel, header, progressBar, graph, nameLabel, timeLabel, itemsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            graph.widthAnchor.constraint(equalTo: stack.widthAnchor),
            graph.heightAnchor.constraint(equalToConstant: 72),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.target = self
        button.action = action
    }

    func update(_ progress: FileOperationProgress) {
        self.progress = progress
        let now = ProcessInfo.processInfo.systemUptime
        // While a copy waits for a download nothing moves: hold the speed and time remaining
        // rather than showing them fall to nothing. The first sample afterwards spans the wait.
        let downloading = progress.downloadingFrom
        if progress.phase == .running, !task.isPaused, downloading == nil {
            let done = progress.totalBytes > 0 ? progress.completedBytes : Int64(progress.completedItems)
            meter.record(bytes: done, at: now)
        }

        if task.isCancelled {
            summaryLabel.stringValue = "Cancelling…"
        } else {
            summaryLabel.stringValue = downloading.map { "Downloading from \($0)…" } ?? summary
        }
        percentLabel.stringValue = titleText
        progressBar.doubleValue = progress.fractionCompleted

        let usesBytes = progress.totalBytes > 0
        graph.isPaused = task.isPaused
        graph.record(fraction: progress.fractionCompleted, speed: meter.bytesPerSecond)
        graph.speedText = meter.bytesPerSecond.map { rate in
            usesBytes ? "Speed: \(FileOperationText.speed(rate))" : "Speed: \(Int(rate.rounded())) items/s"
        }

        nameLabel.stringValue = "Name: \(progress.currentName ?? "")"
        let remaining: TimeInterval?
        if usesBytes {
            remaining = meter.secondsRemaining(totalBytes: progress.totalBytes)
        } else {
            remaining = meter.secondsRemaining(totalBytes: Int64(progress.totalItems))
        }
        timeLabel.stringValue = progress.phase == .preparing
            ? "Time remaining: Calculating…"
            : "Time remaining: \(FileOperationText.timeRemaining(remaining))"
        let itemsLeft = max(0, progress.totalItems - progress.completedItems)
        let bytesLeft = max(0, progress.totalBytes - progress.completedBytes)
        itemsLabel.stringValue = usesBytes
            ? "Items remaining: \(itemsLeft) (\(FileSizeFormat.string(for: bytesLeft)))"
            : "Items remaining: \(itemsLeft)"
    }

    @objc private func togglePause() {
        if task.isPaused {
            task.resume()
            meter.reset()
        } else {
            task.pause()
        }
        let paused = task.isPaused
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: paused ? "Resume" : "Pause"
        )
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        update(progress)
        (window?.windowController as? ProgressWindowController)?.update(task.id, progress: progress)
    }

    @objc private func cancel() {
        task.cancel()
        pauseButton.isEnabled = false
        cancelButton.isEnabled = false
        update(progress)
    }
}
