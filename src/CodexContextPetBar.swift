import Cocoa

let collapsedSize = NSSize(width: 166, height: 18)
let expandedSize = NSSize(width: 360, height: 108)

struct ContextState {
    var threadID = ""
    var threadName = "Codex thread"
    var path: URL?
    var window = 0
    var contextTokens = 0
    var totalTokens = 0
    var level = 0
}

struct ThreadCandidate {
    var path: URL
    var threadID: String
    var threadName: String
    var modifiedAt: Date
    var size: UInt64
}

func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000.0)
    }
    if value >= 1_000 {
        return "\(value / 1_000)K"
    }
    return "\(value)"
}

final class ContextReader {
    private let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private struct FileCache {
        var offset: UInt64 = 0
        var remainder = ""
        var state = ContextState()
        var explicitCompactions = 0
        var inferredCompactions = 0
        var previousContextTokens: Int?
    }
    private var caches: [String: FileCache] = [:]
    private var cachedPaths: [URL] = []
    private var lastPathRefresh = Date.distantPast
    private var namesCache: [String: String] = [:]
    private var namesCacheMtime = Date.distantPast

    func rolloutPaths(force: Bool = false) -> [URL] {
        if !force, Date().timeIntervalSince(lastPathRefresh) < 30, !cachedPaths.isEmpty {
            return cachedPaths
        }

        let sessions = codexHome.appendingPathComponent("sessions")
        let archived = codexHome.appendingPathComponent("archived_sessions")
        var candidates: [URL] = []

        if let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                candidates.append(url)
            }
        }
        if candidates.isEmpty, let enumerator = FileManager.default.enumerator(at: archived, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                candidates.append(url)
            }
        }

        cachedPaths = candidates.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        lastPathRefresh = Date()
        return cachedPaths
    }

    func latestRolloutPath() -> URL? {
        rolloutPaths().first
    }

    func metadata(for path: URL) -> (Date, UInt64)? {
        guard
            let values = try? path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate
        else { return nil }
        return (modified, UInt64(values.fileSize ?? 0))
    }

    func threadNames() -> [String: String] {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        let mtime = (try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if mtime == namesCacheMtime, !namesCache.isEmpty {
            return namesCache
        }

        guard let content = try? String(contentsOf: index, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = object["id"] as? String
            else { continue }
            names[id] = object["thread_name"] as? String ?? "Codex thread"
        }
        namesCache = names
        namesCacheMtime = mtime
        return names
    }

    func candidate(for path: URL, names: [String: String]) -> ThreadCandidate {
        let filename = path.deletingPathExtension().lastPathComponent
        let parts = filename.split(separator: "-")
        let threadID = parts.count >= 7 ? parts.suffix(5).joined(separator: "-") : filename
        let meta = metadata(for: path) ?? (.distantPast, 0)
        return ThreadCandidate(
            path: path,
            threadID: threadID,
            threadName: names[threadID] ?? "Codex thread",
            modifiedAt: meta.0,
            size: meta.1
        )
    }

    func recentCandidates(limit: Int = 8) -> [ThreadCandidate] {
        let names = threadNames()
        return rolloutPaths(force: true).prefix(limit).map { candidate(for: $0, names: names) }
    }

    func read(path requestedPath: URL? = nil) -> ContextState {
        guard let path = requestedPath ?? latestRolloutPath() else {
            return ContextState(threadName: "No Codex thread")
        }

        let key = path.path
        let names = threadNames()
        var cache = caches[key] ?? FileCache(state: ContextState(path: path))
        cache.state.path = path

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
            let fileSizeNumber = attributes[.size] as? NSNumber
        else {
            return cache.state
        }

        let fileSize = fileSizeNumber.uint64Value
        if fileSize < cache.offset {
            cache = FileCache(state: ContextState(path: path))
        }
        if fileSize == cache.offset {
            return cache.state
        }

        guard let handle = try? FileHandle(forReadingFrom: path) else {
            return cache.state
        }
        do {
            try handle.seek(toOffset: cache.offset)
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            cache.offset = fileSize
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
                caches[key] = cache
                return cache.state
            }

            let text = cache.remainder + chunk
            let endsWithNewline = text.last == "\n"
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !endsWithNewline {
                cache.remainder = lines.popLast() ?? ""
            } else {
                cache.remainder = ""
            }

            for line in lines where !line.isEmpty {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let itemType = object["type"] as? String ?? ""
                let payload = object["payload"] as? [String: Any] ?? [:]
                let payloadType = payload["type"] as? String ?? ""

                if itemType == "session_meta" {
                    let id = payload["id"] as? String ?? ""
                    cache.state.threadID = id
                    cache.state.threadName = names[id] ?? payload["thread_name"] as? String ?? "Codex thread"
                }

                if payloadType == "task_started" {
                    cache.state.window = payload["model_context_window"] as? Int ?? cache.state.window
                }

                if payloadType.lowercased().contains("compact") {
                    cache.explicitCompactions += 1
                }

                if payloadType == "token_count" {
                    let info = payload["info"] as? [String: Any] ?? [:]
                    let last = info["last_token_usage"] as? [String: Any] ?? [:]
                    let total = info["total_token_usage"] as? [String: Any] ?? [:]
                    cache.state.window = info["model_context_window"] as? Int ?? cache.state.window

                    let contextTokens = last["input_tokens"] as? Int ?? last["total_tokens"] as? Int ?? 0
                    cache.state.contextTokens = contextTokens
                    cache.state.totalTokens = total["total_tokens"] as? Int ?? cache.state.totalTokens

                    if let previous = cache.previousContextTokens, contextTokens > 0, previous > 60_000, contextTokens < Int(Double(previous) * 0.45) {
                        cache.inferredCompactions += 1
                    }
                    if contextTokens > 0 {
                        cache.previousContextTokens = contextTokens
                    }
                }
            }
        } catch {
            try? handle.close()
        }

        cache.state.level = max(cache.explicitCompactions, cache.inferredCompactions)
        caches[key] = cache
        return cache.state
    }

}

final class ProgressView: NSView {
    var percent: Double = 0
    var barColor = NSColor.systemGreen
    var inlineText = ""
    var showsInlineText = false
    var onClick: (() -> Void)?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let background = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 1.0, alpha: showsInlineText ? 0.18 : 0.13).setFill()
        background.fill()

        let fillWidth = bounds.width * max(0, min(1, percent))
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        (showsInlineText ? barColor.withAlphaComponent(0.82) : barColor).setFill()
        fill.fill()

        let glossRect = NSRect(x: bounds.minX + 3, y: bounds.midY, width: max(0, fillWidth - 6), height: bounds.height / 3)
        let gloss = NSBezierPath(roundedRect: glossRect, xRadius: radius / 2, yRadius: radius / 2)
        NSColor.white.withAlphaComponent(showsInlineText ? 0.16 : 0.28).setFill()
        gloss.fill()

    }
}

final class InlineLabelView: NSView {
    var text = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var fontSize: CGFloat = 9.4
        while fontSize > 8.0 {
            let testAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
            ]
            if (text as NSString).size(withAttributes: testAttributes).width <= bounds.width - 10 {
                break
            }
            fontSize -= 0.4
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.82),
            .paragraphStyle: paragraph
        ]
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(
            x: bounds.minX + 5,
            y: bounds.midY - textHeight / 2 - 0.5,
            width: bounds.width - 10,
            height: textHeight + 2
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

final class RoundedCardView: NSView {
    var isExpanded = false {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?
    private var didDrag = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag, isExpanded {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !isExpanded {
            return
        }

        let cardBounds = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
        let path = NSBezierPath(roundedRect: cardBounds, xRadius: 22, yRadius: 22)
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.18, alpha: 0.34).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        let shine = NSBezierPath(roundedRect: NSRect(x: 18, y: 10, width: bounds.width - 36, height: 20), xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.018).setFill()
        shine.fill()
    }
}

final class PillLabel: NSTextField {
    init(_ text: String, frame: NSRect) {
        super.init(frame: frame)
        stringValue = text
        isBordered = false
        isEditable = false
        drawsBackground = false
        alignment = .center
        textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        font = .systemFont(ofSize: 12, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let reader = ContextReader()
    let window = NSPanel(
        contentRect: NSRect(origin: .zero, size: collapsedSize),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    let content = RoundedCardView(frame: NSRect(origin: .zero, size: collapsedSize))
    let titleLabel = NSTextField(labelWithString: "上下文能量")
    let statsLabel = NSTextField(labelWithString: "Lv0 · 0% · XP0")
    let modeLabel = PillLabel("当前", frame: NSRect(x: 22, y: 82, width: 42, height: 18))
    let threadLabel = NSTextField(labelWithString: "Codex thread")
    let hintLabel = NSTextField(labelWithString: "状态很好 · 0/0")
    let switchButton = NSButton(title: "切换", target: nil, action: nil)
    let autoButton = NSButton(title: "自动", target: nil, action: nil)
    let closeButton = NSButton(title: "×", target: nil, action: nil)
    let progress = ProgressView(frame: NSRect(x: 22, y: 44, width: 252, height: 11))
    let inlineLabel = InlineLabelView(frame: NSRect(origin: .zero, size: collapsedSize))
    let readerQueue = DispatchQueue(label: "local.codex.contextpetbar.reader", qos: .utility)
    var manualMode = false
    var manualPath: URL?
    var activePath: URL?
    var lastObservedSize: UInt64 = 0
    var lastObservedMtime = Date.distantPast
    var isRefreshing = false
    var isExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureWindow()
        refresh(force: true)
        Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in self?.refreshIfChanged() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.collapse(animated: false)
        }
    }

    func configureWindow() {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true

        if let screenFrame = NSScreen.main?.visibleFrame {
            let x = screenFrame.maxX - window.frame.width - 72
            let y = screenFrame.minY + 24
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = false
        window.contentView = content

        titleLabel.frame = NSRect(x: 22, y: 14, width: 104, height: 24)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)

        statsLabel.frame = NSRect(x: 132, y: 14, width: 190, height: 24)
        statsLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        statsLabel.alignment = .right
        statsLabel.font = .systemFont(ofSize: 13, weight: .bold)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.cell?.usesSingleLineMode = true

        hintLabel.frame = NSRect(x: 22, y: 62, width: 252, height: 20)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.82)
        hintLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        modeLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)
        modeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        modeLabel.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor

        threadLabel.frame = NSRect(x: 72, y: 81, width: 202, height: 21)
        threadLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.88)
        threadLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        threadLabel.lineBreakMode = .byTruncatingTail

        configureMiniButton(switchButton, frame: NSRect(x: 292, y: 40, width: 50, height: 22), action: #selector(showThreadMenu))
        configureMiniButton(autoButton, frame: NSRect(x: 292, y: 68, width: 50, height: 22), action: #selector(enableAuto))

        closeButton.frame = NSRect(x: 332, y: 12, width: 18, height: 18)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.56)
        closeButton.font = .systemFont(ofSize: 12, weight: .semibold)
        closeButton.target = NSApp
        closeButton.action = #selector(NSApplication.terminate(_:))

        progress.onClick = { [weak self] in self?.toggleExpanded() }
        content.onClick = { [weak self] in self?.collapse(animated: true) }

        content.addSubview(titleLabel)
        content.addSubview(modeLabel)
        content.addSubview(threadLabel)
        content.addSubview(progress)
        content.addSubview(statsLabel)
        content.addSubview(inlineLabel)
        content.addSubview(hintLabel)
        content.addSubview(switchButton)
        content.addSubview(autoButton)
        content.addSubview(closeButton)
        updateLayout(animated: false)
    }

    func configureMiniButton(_ button: NSButton, frame: NSRect, action: Selector) {
        button.frame = frame
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = frame.height / 2
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        button.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        button.font = .systemFont(ofSize: 9, weight: .semibold)
        button.target = self
        button.action = action
    }

    @objc func showThreadMenu() {
        readerQueue.async { [weak self] in
            guard let self else { return }
            let candidates = self.reader.recentCandidates(limit: 10)
            DispatchQueue.main.async {
                let menu = NSMenu()
                if candidates.isEmpty {
                    let item = NSMenuItem(title: "没有可切换的对话", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                for candidate in candidates {
                    var title = candidate.threadName
                    if title.count > 22 {
                        title = String(title.prefix(21)) + "…"
                    }
                    let item = NSMenuItem(title: title, action: #selector(self.selectThread(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = candidate.path
                    if candidate.path == self.activePath {
                        item.state = .on
                    }
                    menu.addItem(item)
                }
                menu.addItem(.separator())
                let auto = NSMenuItem(title: "自动跟随最近活跃对话", action: #selector(self.enableAuto), keyEquivalent: "")
                auto.target = self
                auto.state = self.manualMode ? .off : .on
                menu.addItem(auto)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.switchButton.bounds.height + 2), in: self.switchButton)
            }
        }
    }

    @objc func selectThread(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? URL else { return }
        manualMode = true
        manualPath = path
        refresh(force: true)
    }

    @objc func enableAuto() {
        manualMode = false
        manualPath = nil
        refresh(force: true)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        updateLayout(animated: true)
    }

    func collapse(animated: Bool) {
        isExpanded = false
        updateLayout(animated: animated)
    }

    func updateLayout(animated: Bool) {
        let targetSize = isExpanded ? expandedSize : collapsedSize
        let oldFrame = window.frame
        let visibleFrame = NSScreen.main?.visibleFrame ?? oldFrame
        let anchoredRight = min(oldFrame.maxX, visibleFrame.maxX - 16)
        let newOrigin = NSPoint(
            x: max(visibleFrame.minX + 16, anchoredRight - targetSize.width),
            y: max(visibleFrame.minY + 16, min(oldFrame.minY, visibleFrame.maxY - targetSize.height - 16))
        )
        let newFrame = NSRect(origin: newOrigin, size: targetSize)
        window.setFrame(newFrame, display: true, animate: animated)
        content.frame = NSRect(origin: .zero, size: targetSize)
        content.isExpanded = isExpanded
        content.needsDisplay = true

        titleLabel.isHidden = !isExpanded
        hintLabel.isHidden = !isExpanded
        modeLabel.isHidden = !isExpanded
        threadLabel.isHidden = !isExpanded
        switchButton.isHidden = !isExpanded
        autoButton.isHidden = !isExpanded
        closeButton.isHidden = !isExpanded

        if isExpanded {
            statsLabel.isHidden = false
            inlineLabel.isHidden = true
            statsLabel.frame = NSRect(x: 132, y: 14, width: 190, height: 24)
            statsLabel.alignment = .right
            statsLabel.font = .systemFont(ofSize: 13, weight: .bold)
            statsLabel.textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            progress.frame = NSRect(x: 22, y: 44, width: 252, height: 11)
            progress.showsInlineText = false
        } else {
            progress.frame = NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
            statsLabel.isHidden = true
            inlineLabel.isHidden = false
            inlineLabel.frame = progress.frame
            progress.showsInlineText = true
        }
        progress.needsDisplay = true
    }

    func refreshIfChanged() {
        let path = manualMode ? manualPath : reader.latestRolloutPath()
        guard let path, let meta = reader.metadata(for: path) else {
            refresh(force: true)
            return
        }
        if path != activePath || meta.0 != lastObservedMtime || meta.1 != lastObservedSize {
            refresh(force: true)
        }
    }

    func refresh(force: Bool) {
        if isRefreshing {
            return
        }
        isRefreshing = true
        let selectedPath = manualMode ? manualPath : nil

        readerQueue.async { [weak self] in
            guard let self else { return }
            let state = self.reader.read(path: selectedPath)
            let meta = state.path.flatMap { self.reader.metadata(for: $0) }
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.activePath = state.path
                if let meta {
                    self.lastObservedMtime = meta.0
                    self.lastObservedSize = meta.1
                }
                self.apply(state)
            }
        }
    }

    func apply(_ state: ContextState) {
        let windowSize = max(state.window, 1)
        let percent = min(100, max(0, Int(round(Double(state.contextTokens) / Double(windowSize) * 100))))

        if percent >= 85 {
            progress.barColor = .systemRed
            hintLabel.stringValue = "建议开新窗口 · \(compactNumber(state.contextTokens))/\(compactNumber(windowSize))"
        } else if percent >= 65 {
            progress.barColor = .systemOrange
            hintLabel.stringValue = "快整理记忆了 · \(compactNumber(state.contextTokens))/\(compactNumber(windowSize))"
        } else {
            progress.barColor = .systemGreen
            hintLabel.stringValue = "状态很好 · \(compactNumber(state.contextTokens))/\(compactNumber(windowSize))"
        }

        var threadName = state.threadName.trimmingCharacters(in: .whitespacesAndNewlines)
        if threadName.isEmpty || threadName == "Codex thread" {
            threadName = "当前对话"
        }
        if threadName.count > 18 {
            threadName = String(threadName.prefix(17)) + "…"
        }
        modeLabel.stringValue = manualMode ? "手动" : "当前"
        modeLabel.layer?.backgroundColor = (manualMode ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.30).cgColor
        threadLabel.stringValue = threadName
        let statsText = "Lv\(state.level) · \(percent)% · XP\(compactNumber(state.totalTokens))"
        statsLabel.stringValue = statsText
        progress.inlineText = statsText
        inlineLabel.text = statsText
        progress.percent = Double(percent) / 100.0
        progress.needsDisplay = true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
