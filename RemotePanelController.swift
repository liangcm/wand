import AppKit
import Carbon.HIToolbox
import ApplicationServices

fileprivate enum PanelSelection: Equatable {
    case button(String)
    case swipe(SwipeDirection)
}

final class RemotePanelController: NSWindowController, NSWindowDelegate {
    private weak var manager: MenuBarManager?
    private let canvas = RemoteCanvasView()
    private let connectionDot = NSView()
    private let connectionLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelImageView = NSImageView()
    private let accessibilityButton = NSButton(title: "", target: nil, action: nil)
    private var permissionTimer: Timer?
    private let selectionLabel = NSTextField(labelWithString: "")
    private let mappingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let helpLabel = NSTextField(wrappingLabelWithString: "")
    private let learnButton = NSButton(title: "学习键盘快捷键…", target: nil, action: nil)
    private let clickMode = NSSegmentedControl(labels: ["单击", "双击"], trackingMode: .selectOne, target: nil, action: nil)
    private let textButton = NSButton(title: "输入文本或命令…", target: nil, action: nil)
    private var learningMonitor: Any?
    private var selection: PanelSelection = .button("siri")

    init(manager: MenuBarManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mavrick 遥控器面板"
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        updateConnectionStatus(manager.isConnected)
        updateRemoteModel(manager.remoteModel)
        updateAccessibilityStatus()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateAccessibilityStatus()
        }
        select(.button("siri"))
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        canvas.refreshLabels()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let title = NSTextField(labelWithString: "Mavrick 遥控器面板")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        connectionDot.wantsLayer = true
        connectionDot.layer?.cornerRadius = 6
        connectionDot.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(connectionDot)

        connectionLabel.font = .systemFont(ofSize: 14)
        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(connectionLabel)

        modelLabel.textColor = .secondaryLabelColor
        modelLabel.font = .systemFont(ofSize: 12)
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modelLabel)
        modelImageView.imageScaling = .scaleProportionallyUpOrDown
        modelImageView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modelImageView)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)
        accessibilityButton.bezelStyle = .inline
        accessibilityButton.isBordered = false
        accessibilityButton.imagePosition = .imageLeading
        accessibilityButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(accessibilityButton)

        canvas.manager = manager
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onSelect = { [weak self] selection in self?.select(selection) }
        content.addSubview(canvas)

        let inspector = NSBox()
        inspector.boxType = .custom
        inspector.cornerRadius = 12
        inspector.borderColor = .separatorColor
        inspector.borderWidth = 1
        inspector.fillColor = .controlBackgroundColor
        inspector.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(inspector)

        let inspectorTitle = NSTextField(labelWithString: "按键设置")
        inspectorTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        inspectorTitle.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(inspectorTitle)

        clickMode.selectedSegment = 0
        clickMode.target = self
        clickMode.action = #selector(clickModeChanged)
        clickMode.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(clickMode)

        let currentCaption = NSTextField(labelWithString: "当前选择")
        currentCaption.textColor = .secondaryLabelColor
        currentCaption.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(currentCaption)

        selectionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        selectionLabel.wantsLayer = true
        selectionLabel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        selectionLabel.layer?.cornerRadius = 8
        selectionLabel.drawsBackground = false
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(selectionLabel)

        let mappingCaption = NSTextField(labelWithString: "按键映射")
        mappingCaption.textColor = .secondaryLabelColor
        mappingCaption.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(mappingCaption)

        mappingPopup.target = self
        mappingPopup.action = #selector(mappingChanged)
        mappingPopup.controlSize = .large
        mappingPopup.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(mappingPopup)

        helpLabel.textColor = .secondaryLabelColor
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(helpLabel)

        learnButton.target = self
        learnButton.action = #selector(startLearning)
        learnButton.bezelStyle = .rounded
        learnButton.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(learnButton)
        textButton.target = self
        textButton.action = #selector(configureTextAction)
        textButton.bezelStyle = .rounded
        textButton.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(textButton)

        let reset = NSButton(title: "恢复默认设置", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(reset)

        let done = NSButton(title: "完成", target: self, action: #selector(closePanel))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(done)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 68),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            connectionLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -28),
            connectionLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modelLabel.trailingAnchor.constraint(equalTo: connectionLabel.trailingAnchor),
            modelLabel.topAnchor.constraint(equalTo: connectionLabel.bottomAnchor, constant: 3),
            modelImageView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            modelImageView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modelImageView.widthAnchor.constraint(equalToConstant: 34),
            modelImageView.heightAnchor.constraint(equalToConstant: 54),
            accessibilityButton.trailingAnchor.constraint(equalTo: connectionDot.leadingAnchor, constant: -24),
            accessibilityButton.centerYAnchor.constraint(equalTo: connectionLabel.centerYAnchor),
            connectionDot.trailingAnchor.constraint(equalTo: connectionLabel.leadingAnchor, constant: -9),
            connectionDot.centerYAnchor.constraint(equalTo: connectionLabel.centerYAnchor),
            connectionDot.widthAnchor.constraint(equalToConstant: 12),
            connectionDot.heightAnchor.constraint(equalToConstant: 12),

            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            canvas.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -16),
            canvas.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.64),

            inspector.leadingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: 18),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            inspector.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 96),
            inspector.heightAnchor.constraint(equalToConstant: 420),
            inspectorTitle.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 26),
            inspectorTitle.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 26),
            currentCaption.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            clickMode.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            clickMode.topAnchor.constraint(equalTo: inspectorTitle.bottomAnchor, constant: 18),
            currentCaption.topAnchor.constraint(equalTo: clickMode.bottomAnchor, constant: 20),
            selectionLabel.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            selectionLabel.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -26),
            selectionLabel.topAnchor.constraint(equalTo: currentCaption.bottomAnchor, constant: 9),
            selectionLabel.heightAnchor.constraint(equalToConstant: 48),
            mappingCaption.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            mappingCaption.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 28),
            mappingPopup.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            mappingPopup.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -26),
            mappingPopup.topAnchor.constraint(equalTo: mappingCaption.bottomAnchor, constant: 9),
            helpLabel.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            helpLabel.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -26),
            helpLabel.topAnchor.constraint(equalTo: mappingPopup.bottomAnchor, constant: 16),
            learnButton.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            learnButton.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 22),
            textButton.leadingAnchor.constraint(equalTo: learnButton.trailingAnchor, constant: 10),
            textButton.centerYAnchor.constraint(equalTo: learnButton.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(equalToConstant: 110),
            reset.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -12),
            reset.centerYAnchor.constraint(equalTo: done.centerYAnchor),
        ])
    }

    func updateConnectionStatus(_ connected: Bool) {
        connectionDot.layer?.backgroundColor = (connected ? NSColor.systemGreen : NSColor.systemGray).cgColor
        connectionLabel.stringValue = connected ? "Siri Remote 已连接" : "Siri Remote 未连接"
    }

    func updateRemoteModel(_ model: AppleRemoteModel) {
        modelLabel.stringValue = model.rawValue
        if let root = Bundle.main.resourceURL?.appendingPathComponent("RemoteModels"),
           let image = NSImage(contentsOf: root.appendingPathComponent(model.imageName)) {
            modelImageView.image = image
        }
        canvas.remoteModel = model
        canvas.needsDisplay = true
    }

    private func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityButton.title = trusted ? "辅助功能：已授权" : "辅助功能：未授权"
        accessibilityButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        accessibilityButton.contentTintColor = trusted ? .systemGreen : .systemRed
        accessibilityButton.toolTip = trusted ? "Mavrick 已可生成键盘和鼠标事件" : "点击前往系统设置授权"
    }

    @objc private func openAccessibilitySettings() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        updateAccessibilityStatus()
    }

    func windowDidBecomeKey(_ notification: Notification) { updateAccessibilityStatus() }

    private func select(_ newSelection: PanelSelection) {
        selection = newSelection
        mappingPopup.removeAllItems()
        guard let manager else { return }
        switch newSelection {
        case .button(let key):
            learnButton.isEnabled = true
            selectionLabel.stringValue = "   \(RemoteCanvasView.buttonName(key))"
            helpLabel.stringValue = holdCapableButtons.contains(key) ? "按住该按键时，将持续执行所选操作。" : "按下该按键时，将执行所选操作。"
            let isDouble = clickMode.selectedSegment == 1
            let actions = isDouble ? manager.availableDoubleClickActions(for: key) : manager.availableActions(for: key)
            for action in actions {
                let learned = isDouble ? manager.learnedDoubleClickShortcut(for: key) : manager.learnedShortcut(for: key)
                let textKey = isDouble ? "double:\(key)" : key
                let title: String
                if action == .customShortcut { title = learned?.label ?? action.displayTitle }
                else if action == .customText { title = manager.textAction(for: textKey)?.text ?? action.displayTitle }
                else { title = action.displayTitle }
                mappingPopup.addItem(withTitle: title)
                mappingPopup.lastItem?.representedObject = action
            }
            let current = isDouble ? manager.getDoubleClickMapping(for: key) : manager.getMapping(for: key)
            if let index = mappingPopup.itemArray.firstIndex(where: { ($0.representedObject as? ButtonAction) == current }) {
                mappingPopup.selectItem(at: index)
            }
        case .swipe(let direction):
            learnButton.isEnabled = false
            textButton.isEnabled = false
            clickMode.selectedSegment = 0
            clickMode.isEnabled = false
            selectionLabel.stringValue = "   \(RemoteCanvasView.swipeName(direction))"
            helpLabel.stringValue = "快速滑动触控板时，将执行所选操作。"
            for action in manager.availableSwipeActions(for: direction) {
                mappingPopup.addItem(withTitle: action.displayTitle)
                mappingPopup.lastItem?.representedObject = action
            }
            let current = manager.getSwipeMapping(for: direction)
            if let index = mappingPopup.itemArray.firstIndex(where: { ($0.representedObject as? SwipeAction) == current }) {
                mappingPopup.selectItem(at: index)
            }
        }
        if case .button = newSelection { clickMode.isEnabled = true; textButton.isEnabled = true }
        canvas.selection = newSelection
        canvas.needsDisplay = true
    }

    @objc private func mappingChanged() {
        guard let manager, let item = mappingPopup.selectedItem else { return }
        switch selection {
        case .button(let key):
            if let action = item.representedObject as? ButtonAction {
                if clickMode.selectedSegment == 1 { manager.setDoubleClickMapping(action, for: key) }
                else { manager.setMapping(action, for: key) }
            }
        case .swipe(let direction):
            if let action = item.representedObject as? SwipeAction { manager.setSwipeMapping(action, for: direction) }
        }
        canvas.refreshLabels()
    }

    @objc private func resetDefaults() {
        manager?.resetMappingsToDefaults()
        select(selection)
        canvas.refreshLabels()
    }

    @objc private func startLearning() {
        guard case .button = selection else { return }
        stopLearning()
        learnButton.title = "请按键盘按键或组合键…（Esc 取消）"
        helpLabel.stringValue = "正在学习：例如按 Command + K、Shift + Tab 或单个按键。"
        window?.makeKey()
        learningMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
                self.stopLearning()
                self.select(self.selection)
                return nil
            }
            guard !event.isARepeat, let shortcut = self.shortcut(from: event) else { return nil }
            if case .button(let key) = self.selection {
                if self.clickMode.selectedSegment == 1 { self.manager?.setLearnedDoubleClickShortcut(shortcut, for: key) }
                else { self.manager?.setLearnedShortcut(shortcut, for: key) }
                self.stopLearning()
                self.select(.button(key))
                self.canvas.refreshLabels()
            }
            return nil
        }
    }

    @objc private func configureTextAction() {
        guard case .button(let key) = selection, let manager else { return }
        let isDouble = clickMode.selectedSegment == 1
        let storageKey = isDouble ? "double:\(key)" : key
        let alert = NSAlert()
        alert.messageText = "输入文本或命令"
        alert.informativeText = "例如 /compact，并选择输入后的操作。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: manager.textAction(for: storageKey)?.text ?? "")
        field.placeholderString = "/compact"
        let suffix = NSPopUpButton()
        suffix.addItems(withTitles: ["不追加", "追加空格", "追加 Enter"])
        if let current = manager.textAction(for: storageKey) {
            suffix.selectItem(at: current.suffix == .none ? 0 : current.suffix == .space ? 1 : 2)
        }
        let stack = NSStackView(views: [field, suffix])
        stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 62)
        alert.accessoryView = stack
        window?.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue
        guard !value.isEmpty else { return }
        let ending: TextActionSuffix = suffix.indexOfSelectedItem == 1 ? .space : suffix.indexOfSelectedItem == 2 ? .enter : .none
        manager.setTextAction(TextActionSpec(text: value, suffix: ending), for: key, doubleClick: isDouble)
        select(selection); canvas.refreshLabels()
    }

    private func stopLearning() {
        if let monitor = learningMonitor { NSEvent.removeMonitor(monitor) }
        learningMonitor = nil
        learnButton.title = "学习键盘快捷键…"
    }

    private func shortcut(from event: NSEvent) -> LearnedShortcut? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var flags: CGEventFlags = []
        var parts: [String] = []
        if mods.contains(.control) { flags.insert(.maskControl); parts.append("⌃") }
        if mods.contains(.option)  { flags.insert(.maskAlternate); parts.append("⌥") }
        if mods.contains(.shift)   { flags.insert(.maskShift); parts.append("⇧") }
        if mods.contains(.command) { flags.insert(.maskCommand); parts.append("⌘") }
        if mods.contains(.function) { flags.insert(.maskSecondaryFn); parts.append("Fn") }

        if event.type == .flagsChanged {
            guard !parts.isEmpty else { return nil }
            let name = Self.specialKeyNames[event.keyCode] ?? parts.last ?? "修饰键"
            return LearnedShortcut(keyCode: event.keyCode, flagsRawValue: flags.rawValue, label: parts.dropLast().joined() + name)
        }

        guard event.type == .keyDown else { return nil }
        let keyName = Self.specialKeyNames[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "Key \(event.keyCode)"
        parts.append(keyName)
        return LearnedShortcut(keyCode: event.keyCode, flagsRawValue: flags.rawValue, label: parts.joined())
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Home): "Home", UInt16(kVK_End): "End", UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Control): "左 Control", UInt16(kVK_RightControl): "右 Control",
        UInt16(kVK_Command): "左 Command", UInt16(kVK_RightCommand): "右 Command",
        UInt16(kVK_Shift): "左 Shift", UInt16(kVK_RightShift): "右 Shift",
        UInt16(kVK_Option): "左 Option", UInt16(kVK_RightOption): "右 Option"
    ]

    @objc private func clickModeChanged() { select(selection) }

    @objc private func closePanel() { stopLearning(); close() }

    deinit { permissionTimer?.invalidate() }
}

final class RemoteCanvasView: NSView {
    weak var manager: MenuBarManager?
    fileprivate var onSelect: ((PanelSelection) -> Void)?
    fileprivate var selection: PanelSelection = .button("siri")
    var remoteModel: AppleRemoteModel = .unknown
    private var hitAreas: [(NSRect, PanelSelection)] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        hitAreas.removeAll()
        // Match the approved concept proportions: a broad, tall remote centered in
        // the left stage with generous space for horizontal mapping callouts.
        let remote = NSRect(x: bounds.midX - 125, y: 42, width: 250, height: 610)
        if remoteModel == .a1513 {
            drawFirstGeneration(in: remote)
            return
        }
        let body = NSBezierPath(roundedRect: remote, xRadius: 34, yRadius: 34)
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        body.fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
        body.lineWidth = 1.5
        body.stroke()

        // Newer Siri Remote: a dedicated power button sits at the upper-right,
        // above the clickpad. Siri/voice is a separate button on the right edge.
        addButton("power", center: NSPoint(x: remote.maxX - 31, y: remote.minY + 29), symbol: "⏻", labelPoint: NSPoint(x: remote.maxX + 20, y: remote.minY + 13), align: .left)

        let pad = NSRect(x: remote.midX - 88, y: remote.minY + 58, width: 176, height: 176)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: pad).fill()
        NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: pad.insetBy(dx: 7, dy: 7)); ring.lineWidth = 2; ring.stroke()
        let padCenter = pad.insetBy(dx: 43, dy: 43)
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSBezierPath(ovalIn: padCenter).fill()
        hitAreas.append((padCenter, .button("select")))
        drawText("点击", at: NSPoint(x: padCenter.midX, y: padCenter.midY - 8), width: 70, align: .center, color: NSColor.white.withAlphaComponent(0.55), size: 11)

        addSwipe(.up, rect: NSRect(x: pad.midX - 34, y: pad.minY, width: 68, height: 38), anchor: NSPoint(x: pad.midX, y: pad.minY), labelPoint: NSPoint(x: pad.midX, y: 15), align: .center)
        addSwipe(.down, rect: NSRect(x: pad.midX - 34, y: pad.maxY - 38, width: 68, height: 38), anchor: NSPoint(x: pad.midX, y: pad.maxY), labelPoint: NSPoint(x: pad.midX, y: pad.maxY + 16), align: .center)
        addSwipe(.left, rect: NSRect(x: pad.minX, y: pad.midY - 34, width: 38, height: 68), anchor: NSPoint(x: pad.minX, y: pad.midY), labelPoint: NSPoint(x: remote.minX - 18, y: pad.midY - 8), align: .right)
        addSwipe(.right, rect: NSRect(x: pad.maxX - 38, y: pad.midY - 34, width: 38, height: 68), anchor: NSPoint(x: pad.maxX, y: pad.midY), labelPoint: NSPoint(x: remote.maxX + 18, y: pad.midY - 8), align: .left)

        let leftX = remote.minX + 62, rightX = remote.maxX - 62
        addButton("menu", center: NSPoint(x: leftX, y: remote.minY + 310), symbol: "‹", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 299), align: .right)
        addButton("tv", center: NSPoint(x: rightX, y: remote.minY + 310), symbol: "▣", labelPoint: NSPoint(x: remote.maxX + 20, y: remote.minY + 299), align: .left)
        addButton("playPause", center: NSPoint(x: leftX, y: remote.minY + 392), symbol: "▶Ⅱ", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 381), align: .right)
        addVolumeRocker(center: NSPoint(x: rightX, y: remote.minY + 416), remote: remote)
        addButton("mute", center: NSPoint(x: leftX, y: remote.minY + 474), symbol: "", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 463), align: .right)
        addSideSiri(remote: remote, pad: pad)
    }

    func refreshLabels() { needsDisplay = true }

    private func drawFirstGeneration(in remote: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: remote, xRadius: 28, yRadius: 28).fill()
        let touch = NSRect(x: remote.minX + 18, y: remote.minY + 22, width: remote.width - 36, height: 205)
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: touch, xRadius: 18, yRadius: 18).fill()
        let center = touch.insetBy(dx: 62, dy: 58)
        hitAreas.append((center, .button("select")))
        drawText("点击", at: NSPoint(x: center.midX, y: center.midY - 8), width: 70, align: .center, color: NSColor.white.withAlphaComponent(0.55), size: 11)
        addSwipe(.up, rect: NSRect(x: touch.midX - 45, y: touch.minY, width: 90, height: 50), anchor: NSPoint(x: touch.midX, y: touch.minY), labelPoint: NSPoint(x: touch.midX, y: 8), align: .center)
        addSwipe(.down, rect: NSRect(x: touch.midX - 45, y: touch.maxY - 50, width: 90, height: 50), anchor: NSPoint(x: touch.midX, y: touch.maxY), labelPoint: NSPoint(x: touch.midX, y: touch.maxY + 8), align: .center)
        addSwipe(.left, rect: NSRect(x: touch.minX, y: touch.midY - 45, width: 50, height: 90), anchor: NSPoint(x: touch.minX, y: touch.midY), labelPoint: NSPoint(x: remote.minX - 18, y: touch.midY - 8), align: .right)
        addSwipe(.right, rect: NSRect(x: touch.maxX - 50, y: touch.midY - 45, width: 50, height: 90), anchor: NSPoint(x: touch.maxX, y: touch.midY), labelPoint: NSPoint(x: remote.maxX + 18, y: touch.midY - 8), align: .left)
        let lx = remote.minX + 62, rx = remote.maxX - 62
        addButton("menu", center: NSPoint(x: lx, y: remote.minY + 292), symbol: "MENU", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 281), align: .right)
        addButton("tv", center: NSPoint(x: rx, y: remote.minY + 292), symbol: "▣", labelPoint: NSPoint(x: remote.maxX + 20, y: remote.minY + 281), align: .left)
        addButton("siri", center: NSPoint(x: lx, y: remote.minY + 372), symbol: "◉", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 361), align: .right)
        addVolumeRocker(center: NSPoint(x: rx, y: remote.minY + 405), remote: remote)
        addButton("playPause", center: NSPoint(x: lx, y: remote.minY + 460), symbol: "▶Ⅱ", labelPoint: NSPoint(x: remote.minX - 20, y: remote.minY + 449), align: .right)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = hitAreas.reversed().first(where: { $0.0.contains(point) })?.1 { onSelect?(target) }
    }

    private func addButton(_ key: String, center: NSPoint, symbol: String, labelPoint: NSPoint, align: NSTextAlignment) {
        let rect = NSRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50)
        hitAreas.append((rect, .button(key)))
        let selected = selection == .button(key)
        (selected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.13, alpha: 1)).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if key == "mute", let image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "静音") {
            let configured = image.withSymbolConfiguration(.init(pointSize: 19, weight: .medium)) ?? image
            configured.isTemplate = true
            NSColor.white.set()
            configured.draw(in: NSRect(x: rect.midX - 12, y: rect.midY - 12, width: 24, height: 24))
        } else {
            drawText(symbol, at: NSPoint(x: rect.midX, y: rect.midY - 11), width: 46, align: .center, color: .white, size: 22)
        }
        drawLeader(from: align == .right ? NSPoint(x: rect.minX, y: rect.midY) : align == .left ? NSPoint(x: rect.maxX, y: rect.midY) : NSPoint(x: rect.midX, y: rect.maxY), to: labelPoint, selected: selected)
        let action = manager?.getMapping(for: key).displayTitle ?? ""
        drawText("\(Self.buttonName(key))\n\(short(action))", at: labelPoint, width: 170, align: align, color: .labelColor, size: 13)
    }

    private func addSideSiri(remote: NSRect, pad: NSRect) {
        // The physical side voice key is aligned with the clickpad/right-swipe zone.
        let rect = NSRect(x: remote.maxX - 3, y: pad.midY - 31, width: 12, height: 62)
        hitAreas.append((rect.insetBy(dx: -10, dy: -5), .button("siri")))
        let selected = selection == .button("siri")
        (selected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.16, alpha: 1)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let anchor = NSPoint(x: rect.maxX, y: rect.midY)
        let labelPoint = NSPoint(x: remote.maxX + 20, y: pad.maxY + 16)
        drawLeader(from: anchor, to: labelPoint, selected: selected)
        let action = manager?.getMapping(for: "siri").displayTitle ?? ""
        drawText("侧边 Siri/语音键\n\(short(action))", at: labelPoint, width: 180, align: .left, color: .labelColor, size: 13)
    }

    private func addVolumeRocker(center: NSPoint, remote: NSRect) {
        let rocker = NSRect(x: center.x - 27, y: center.y - 70, width: 54, height: 140)
        let upRect = NSRect(x: rocker.minX, y: rocker.minY, width: rocker.width, height: rocker.height / 2)
        let downRect = NSRect(x: rocker.minX, y: rocker.midY, width: rocker.width, height: rocker.height / 2)
        hitAreas.append((upRect, .button("volumeUp")))
        hitAreas.append((downRect, .button("volumeDown")))
        let selected = selection == .button("volumeUp") || selection == .button("volumeDown")
        (selected ? NSColor.systemBlue : NSColor(calibratedWhite: 0.13, alpha: 1)).setFill()
        NSBezierPath(roundedRect: rocker, xRadius: 25, yRadius: 25).fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
        let divider = NSBezierPath(); divider.move(to: NSPoint(x: rocker.minX + 9, y: rocker.midY)); divider.line(to: NSPoint(x: rocker.maxX - 9, y: rocker.midY)); divider.stroke()
        drawText("+", at: NSPoint(x: rocker.midX, y: rocker.minY + 16), width: 48, align: .center, color: .white, size: 25)
        drawText("−", at: NSPoint(x: rocker.midX, y: rocker.midY + 16), width: 48, align: .center, color: .white, size: 25)
        let upAction = manager?.getMapping(for: "volumeUp").displayTitle ?? ""
        let downAction = manager?.getMapping(for: "volumeDown").displayTitle ?? ""
        let upPoint = NSPoint(x: remote.maxX + 20, y: rocker.minY + 18)
        let downPoint = NSPoint(x: remote.maxX + 20, y: rocker.midY + 18)
        drawLeader(from: NSPoint(x: rocker.maxX, y: rocker.minY + rocker.height * 0.25), to: upPoint, selected: selection == .button("volumeUp"))
        drawLeader(from: NSPoint(x: rocker.maxX, y: rocker.minY + rocker.height * 0.75), to: downPoint, selected: selection == .button("volumeDown"))
        drawText("音量加\n\(short(upAction))", at: upPoint, width: 170, align: .left, color: .labelColor, size: 13)
        drawText("音量减\n\(short(downAction))", at: downPoint, width: 170, align: .left, color: .labelColor, size: 13)
    }

    private func addSwipe(_ direction: SwipeDirection, rect: NSRect, anchor: NSPoint, labelPoint: NSPoint, align: NSTextAlignment) {
        hitAreas.append((rect, .swipe(direction)))
        let selected = selection == .swipe(direction)
        drawLeader(from: anchor, to: labelPoint, selected: selected)
        let action = manager?.getSwipeMapping(for: direction).displayTitle ?? ""
        drawText("\(Self.swipeName(direction))  \(short(action))", at: labelPoint, width: 190, align: align, color: .labelColor, size: 13)
    }

    private func drawLeader(from: NSPoint, to: NSPoint, selected: Bool) {
        let p = NSBezierPath(); p.move(to: from); p.line(to: to); p.lineWidth = selected ? 2 : 1
        (selected ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.65)).setStroke(); p.stroke()
        (selected ? NSColor.systemBlue : NSColor.white).setFill(); NSBezierPath(ovalIn: NSRect(x: from.x - 4, y: from.y - 4, width: 8, height: 8)).fill()
    }

    private func drawText(_ text: String, at point: NSPoint, width: CGFloat, align: NSTextAlignment, color: NSColor, size: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = align
        let x = align == .right ? point.x - width : align == .center ? point.x - width / 2 : point.x
        text.draw(in: NSRect(x: x, y: point.y, width: width, height: 45), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
    }

    private func short(_ title: String) -> String { title.components(separatedBy: "：").last ?? title }

    static func buttonName(_ key: String) -> String {
        ["select":"触控板中心点击", "menu":"返回键", "tv":"TV 键", "siri":"侧边 Siri/语音键", "playPause":"播放/暂停", "volumeUp":"音量加", "volumeDown":"音量减", "mute":"静音键", "power":"电源键"][key] ?? key
    }

    static func swipeName(_ direction: SwipeDirection) -> String {
        switch direction { case .up: return "向上滑"; case .down: return "向下滑"; case .left: return "向左滑"; case .right: return "向右滑" }
    }
}
