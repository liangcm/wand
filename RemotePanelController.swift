import AppKit
import Carbon.HIToolbox
import ApplicationServices

fileprivate enum PanelSelection: Equatable {
    case button(String)
}

/// A rounded-rect background whose fill re-resolves on light/dark switches. Assigning a `.cgColor`
/// to layer.backgroundColor directly would freeze the color, since cgColor is a static snapshot of
/// the appearance at assignment time. updateLayer re-runs on appearance changes, keeping it correct.
final class RoundedBackgroundView: NSView {
    var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
        layer?.cornerRadius = cornerRadius
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class RemotePanelController: NSWindowController, NSWindowDelegate {
    private weak var manager: MenuBarManager?
    private let canvas = RemoteCanvasView()
    private let connectionDot = RoundedBackgroundView()
    private let connectionLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "", target: nil, action: nil)
    private var permissionTimer: Timer?
    private let selectionLabel = NSTextField(labelWithString: "")
    private let selectionBG = RoundedBackgroundView()
    private let mappingButton = NSButton(title: "", target: nil, action: nil)
    private var mappingMenu: NSMenu?
    private let helpLabel = NSTextField(wrappingLabelWithString: "")
    private let learnButton = NSButton(title: tr("panel.learnButton"), target: nil, action: nil)
    private let clickMode = NSSegmentedControl(labels: [tr("panel.clickMode.single"), tr("panel.clickMode.double")], trackingMode: .selectOne, target: nil, action: nil)
    private let textButton = NSButton(title: tr("panel.textButton"), target: nil, action: nil)
    private let appButton = NSButton(title: tr("panel.appButton"), target: nil, action: nil)
    private let dpadStepSlider = NSSlider(value: 20, minValue: 5, maxValue: 80, target: nil, action: nil)
    private let dpadStepCaption = NSTextField(labelWithString: tr("panel.sensitivity"))
    private let dpadStepValue = NSTextField(labelWithString: "20")
    private let tapToggle = NSButton(checkboxWithTitle: tr("panel.tapToClick"), target: nil, action: nil)
    private let accessorySettingsButton = NSButton(title: tr("panel.accessibilitySettings"), target: nil, action: nil)
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
        window.title = tr("panel.title")
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        updateConnectionStatus(manager.isConnected)
        updateRemoteModel(manager.remoteModel)
        updateAccessibilityStatus()
        startPermissionTimer()
        select(.button("siri"))
    }

    private func startPermissionTimer() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateAccessibilityStatus()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        startPermissionTimer()   // windowWillClose stops it; restart on reopen
        canvas.refreshLabels()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        // No explicit layer background — the window's own backgroundColor (windowBackgroundColor)
        // shows through and tracks light/dark. Setting layer.backgroundColor to a .cgColor here
        // would freeze the color at first paint and not follow appearance changes.

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        let title = NSTextField(labelWithString: tr("panel.title"))
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        connectionDot.cornerRadius = 6
        connectionDot.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(connectionDot)

        connectionLabel.font = .systemFont(ofSize: 14)
        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(connectionLabel)

        modelLabel.textColor = .secondaryLabelColor
        modelLabel.font = .systemFont(ofSize: 12)
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modelLabel)

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

        let inspectorTitle = NSTextField(labelWithString: tr("panel.inspectorTitle"))
        inspectorTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        inspectorTitle.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(inspectorTitle)

        clickMode.selectedSegment = 0
        clickMode.target = self
        clickMode.action = #selector(clickModeChanged)
        clickMode.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(clickMode)

        let currentCaption = NSTextField(labelWithString: tr("panel.currentSelection"))
        currentCaption.textColor = .secondaryLabelColor
        currentCaption.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(currentCaption)

        selectionBG.fillColor = .windowBackgroundColor
        selectionBG.cornerRadius = 8
        selectionBG.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(selectionBG)   // added before the label so it sits behind it
        selectionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        selectionLabel.drawsBackground = false
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(selectionLabel)

        let mappingCaption = NSTextField(labelWithString: tr("panel.mappingCaption"))
        mappingCaption.textColor = .secondaryLabelColor
        mappingCaption.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(mappingCaption)

        mappingButton.target = self
        mappingButton.action = #selector(showMappingMenu)
        mappingButton.bezelStyle = .rounded
        mappingButton.controlSize = .large
        mappingButton.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(mappingButton)

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
        appButton.target = self
        appButton.action = #selector(configureAppAction)
        appButton.bezelStyle = .rounded
        appButton.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(appButton)

        // Global setting: how far each trackpad direction click moves the cursor.
        dpadStepCaption.textColor = .secondaryLabelColor
        dpadStepCaption.font = .systemFont(ofSize: 13)
        dpadStepCaption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dpadStepCaption)
        dpadStepSlider.doubleValue = Double(manager?.dpadStep ?? 20)
        dpadStepSlider.target = self
        dpadStepSlider.action = #selector(dpadStepChanged)
        dpadStepSlider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dpadStepSlider)
        dpadStepValue.font = .systemFont(ofSize: 13, weight: .medium)
        dpadStepValue.stringValue = "\(Int(manager?.dpadStep ?? 20))"
        dpadStepValue.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dpadStepValue)

        // Global setting: whether a light tap (no physical press) clicks. Off = press-only.
        tapToggle.state = (manager?.tapToClickEnabled == false) ? .off : .on
        tapToggle.target = self
        tapToggle.action = #selector(tapToggleChanged)
        tapToggle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tapToggle)

        // Extra accessibility entry point in the footer (mirrors the header status badge).
        accessorySettingsButton.target = self
        accessorySettingsButton.action = #selector(openAccessibilitySettings)
        accessorySettingsButton.bezelStyle = .rounded
        accessorySettingsButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(accessorySettingsButton)

        let reset = NSButton(title: tr("panel.resetDefaults"), target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(reset)

        let done = NSButton(title: tr("panel.done"), target: self, action: #selector(closePanel))
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
            accessibilityButton.trailingAnchor.constraint(equalTo: connectionDot.leadingAnchor, constant: -24),
            accessibilityButton.centerYAnchor.constraint(equalTo: connectionLabel.centerYAnchor),
            connectionDot.trailingAnchor.constraint(equalTo: connectionLabel.leadingAnchor, constant: -9),
            connectionDot.centerYAnchor.constraint(equalTo: connectionLabel.centerYAnchor),
            connectionDot.widthAnchor.constraint(equalToConstant: 12),
            connectionDot.heightAnchor.constraint(equalToConstant: 12),

            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            canvas.bottomAnchor.constraint(equalTo: tapToggle.topAnchor, constant: -12),
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
            selectionBG.leadingAnchor.constraint(equalTo: selectionLabel.leadingAnchor),
            selectionBG.trailingAnchor.constraint(equalTo: selectionLabel.trailingAnchor),
            selectionBG.topAnchor.constraint(equalTo: selectionLabel.topAnchor),
            selectionBG.bottomAnchor.constraint(equalTo: selectionLabel.bottomAnchor),
            mappingCaption.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            mappingCaption.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 28),
            mappingButton.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            mappingButton.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -26),
            mappingButton.topAnchor.constraint(equalTo: mappingCaption.bottomAnchor, constant: 9),
            helpLabel.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            helpLabel.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -26),
            helpLabel.topAnchor.constraint(equalTo: mappingButton.bottomAnchor, constant: 16),
            learnButton.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            learnButton.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 22),
            textButton.leadingAnchor.constraint(equalTo: learnButton.trailingAnchor, constant: 10),
            textButton.centerYAnchor.constraint(equalTo: learnButton.centerYAnchor),
            // Third button wraps to its own row — three across overflows the inspector.
            appButton.leadingAnchor.constraint(equalTo: inspectorTitle.leadingAnchor),
            appButton.topAnchor.constraint(equalTo: learnButton.bottomAnchor, constant: 10),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(equalToConstant: 110),
            reset.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -12),
            reset.centerYAnchor.constraint(equalTo: done.centerYAnchor),

            // Footer row above the buttons: tap-to-click + mouse sensitivity, right-aligned.
            dpadStepValue.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            dpadStepValue.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -14),
            dpadStepSlider.trailingAnchor.constraint(equalTo: dpadStepValue.leadingAnchor, constant: -8),
            dpadStepSlider.centerYAnchor.constraint(equalTo: dpadStepValue.centerYAnchor),
            dpadStepSlider.widthAnchor.constraint(equalToConstant: 160),
            dpadStepCaption.trailingAnchor.constraint(equalTo: dpadStepSlider.leadingAnchor, constant: -10),
            dpadStepCaption.centerYAnchor.constraint(equalTo: dpadStepValue.centerYAnchor),
            tapToggle.trailingAnchor.constraint(equalTo: dpadStepCaption.leadingAnchor, constant: -24),
            tapToggle.centerYAnchor.constraint(equalTo: dpadStepValue.centerYAnchor),
            // Accessibility settings entry, bottom-left, aligned with Done.
            accessorySettingsButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            accessorySettingsButton.centerYAnchor.constraint(equalTo: done.centerYAnchor),
        ])
    }

    func updateConnectionStatus(_ connected: Bool) {
        connectionDot.fillColor = connected ? .systemGreen : .systemGray
        connectionLabel.stringValue = connected ? tr("panel.connected") : tr("panel.disconnected")
    }

    func updateRemoteModel(_ model: AppleRemoteModel) {
        modelLabel.stringValue = model.displayName
        canvas.remoteModel = model
        canvas.needsDisplay = true
    }

    private func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityButton.title = trusted ? tr("panel.ax.granted") : tr("panel.ax.denied")
        accessibilityButton.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        accessibilityButton.contentTintColor = trusted ? .systemGreen : .systemRed
        accessibilityButton.toolTip = trusted ? tr("panel.ax.tooltip.granted") : tr("panel.ax.tooltip.denied")
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

    /// The mapping target the inspector is currently editing. Buttons honour the single/double
    /// click segment.
    private var currentTarget: MappingTarget {
        switch selection {
        case .button(let key):
            return clickMode.selectedSegment == 1 ? .doubleClick(key) : .button(key)
        }
    }

    private func select(_ newSelection: PanelSelection) {
        // Switching targets mid-learning would capture the shortcut for the OLD target —
        // treat a selection change as an implicit cancel.
        if learningMonitor != nil { stopLearning() }

        let selectionChanged = (selection != newSelection)
        selection = newSelection
        guard let manager else { return }

        // Trackpad centre click uses a fixed stateful workflow in the HID handler.
        let locked = (newSelection == .button("select"))

        switch newSelection {
        case .button(let key):
            selectionLabel.stringValue = "   \(RemoteCanvasView.buttonName(key))"
            if key == "select" {
                helpLabel.stringValue = tr("panel.help.selectLocked")
            } else {
                helpLabel.stringValue = tr("panel.help.button")
            }
            // Coming from another key, start on 单击 — otherwise the segment silently carries
            // over and edits land on the new key's DOUBLE-click target. Not reset when the
            // selection is unchanged (clickModeChanged() re-enters here to refresh the menu).
            if selectionChanged { clickMode.selectedSegment = 0 }
            clickMode.isEnabled = !locked
        }

        rebuildMappingMenu(for: currentTarget, manager: manager)
        mappingButton.isEnabled = !locked
        learnButton.isEnabled = !locked
        textButton.isEnabled = !locked
        appButton.isEnabled = !locked

        canvas.selection = newSelection
        canvas.needsDisplay = true
    }

    /// Builds the mapping menu as three category submenus (功能键 / F 键 / 组合键) plus the
    /// special actions flat, and sets the button's title to the current binding. A plain button
    /// + popped menu (rather than NSPopUpButton) so the current value always shows, even when
    /// it lives inside a submenu.
    private func rebuildMappingMenu(for target: MappingTarget, manager: MenuBarManager) {
        let available = manager.availableActions(for: target)
        let current = manager.mapping(for: target)
        let menu = NSMenu()

        func makeItem(_ action: RemoteAction) -> NSMenuItem {
            let item = NSMenuItem(title: manager.displayTitle(for: action, target: target),
                                  action: #selector(mappingItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            if action == current { item.state = .on }
            return item
        }
        func addSubmenu(_ title: String, _ actions: [RemoteAction]) {
            guard !actions.isEmpty else { return }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            actions.forEach { sub.addItem(makeItem($0)) }
            parent.submenu = sub
            // Surface the checkmark at the top level too, so the active category is visible
            // without opening each submenu.
            if actions.contains(current) { parent.state = .on }
            menu.addItem(parent)
        }

        addSubmenu(tr("panel.category.functionKeys"), available.filter { $0.category == .functionKey })
        addSubmenu(tr("panel.category.fKeys"), available.filter { $0.category == .fKey })
        addSubmenu(tr("panel.category.combos"), available.filter { $0.category == .combo })
        menu.addItem(.separator())
        available.filter { $0.category == .special }.forEach { menu.addItem(makeItem($0)) }

        mappingMenu = menu
        mappingButton.title = manager.displayTitle(for: manager.mapping(for: target), target: target)
    }

    @objc private func showMappingMenu() {
        guard let menu = mappingMenu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: mappingButton.bounds.height + 4),
                   in: mappingButton)
    }

    @objc private func mappingItemChosen(_ sender: NSMenuItem) {
        guard let manager, let action = sender.representedObject as? RemoteAction else { return }
        manager.setMapping(action, for: currentTarget)
        mappingButton.title = manager.displayTitle(for: action, target: currentTarget)
        canvas.refreshLabels()
    }

    @objc private func dpadStepChanged() {
        manager?.setDpadStep(CGFloat(dpadStepSlider.doubleValue))
        dpadStepValue.stringValue = "\(Int(dpadStepSlider.doubleValue))"
    }

    @objc private func tapToggleChanged() {
        manager?.setTapToClickEnabled(tapToggle.state == .on)
    }

    @objc private func resetDefaults() {
        manager?.resetMappingsToDefaults()
        select(selection)
        canvas.refreshLabels()
    }

    @objc private func startLearning() {
        stopLearning()
        let target = currentTarget
        learnButton.title = tr("panel.learnButton.active")
        helpLabel.stringValue = tr("panel.help.learning")
        window?.makeKey()
        learningMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
                self.stopLearning()
                self.select(self.selection)
                return nil
            }
            guard !event.isARepeat, let shortcut = self.shortcut(from: event) else { return nil }
            self.manager?.setLearnedShortcut(shortcut, for: target)
            self.stopLearning()
            self.select(self.selection)
            self.canvas.refreshLabels()
            return nil
        }
    }

    @objc private func configureTextAction() {
        guard let manager else { return }
        let target = currentTarget
        let alert = NSAlert()
        alert.messageText = tr("alert.text.title")
        alert.informativeText = tr("alert.text.message")
        alert.addButton(withTitle: tr("alert.save"))
        alert.addButton(withTitle: tr("alert.cancel"))
        let field = NSTextField(string: manager.textAction(for: target)?.text ?? "")
        field.placeholderString = "/compact"
        let suffix = NSPopUpButton()
        suffix.addItems(withTitles: [tr("alert.text.suffix.none"), tr("alert.text.suffix.space"), tr("alert.text.suffix.enter")])
        if let current = manager.textAction(for: target) {
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
        manager.setTextAction(TextActionSpec(text: value, suffix: ending), for: target)
        select(selection); canvas.refreshLabels()
    }

    /// Pick an app for this input to launch. Lists what's installed, searchable by typing.
    @objc private func configureAppAction() {
        guard let manager else { return }
        let target = currentTarget
        let apps = InstalledApps.all()

        let alert = NSAlert()
        alert.messageText = tr("alert.app.title")
        alert.informativeText = tr("alert.app.message")
        alert.addButton(withTitle: tr("alert.save"))
        alert.addButton(withTitle: tr("alert.cancel"))
        alert.addButton(withTitle: tr("alert.app.other"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        for app in apps { popup.addItem(withTitle: app.name); popup.lastItem?.representedObject = app.bundleID }
        if let current = manager.appAction(for: target),
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: index)
        }
        alert.accessoryView = popup

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let bundleID = popup.selectedItem?.representedObject as? String else { return }
            manager.setAppAction(bundleID: bundleID, for: target)
        case .alertThirdButtonReturn:
            guard let bundleID = chooseAppFromDisk() else { return }
            manager.setAppAction(bundleID: bundleID, for: target)
        default:
            return
        }
        select(selection); canvas.refreshLabels()
    }

    /// Fallback for apps outside the scanned Applications folders.
    private func chooseAppFromDisk() -> String? {
        let panel = NSOpenPanel()
        panel.title = tr("alert.app.panelTitle")
        panel.prompt = tr("alert.app.panelPrompt")
        panel.allowedFileTypes = ["app"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private func stopLearning() {
        if let monitor = learningMonitor { NSEvent.removeMonitor(monitor) }
        learningMonitor = nil
        learnButton.title = tr("panel.learnButton")
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
            let name = Self.specialKeyNames[event.keyCode] ?? parts.last ?? tr("key.modifier")
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
        UInt16(kVK_Control): tr("key.leftControl"), UInt16(kVK_RightControl): tr("key.rightControl"),
        UInt16(kVK_Command): tr("key.leftCommand"), UInt16(kVK_RightCommand): tr("key.rightCommand"),
        UInt16(kVK_Shift): tr("key.leftShift"), UInt16(kVK_RightShift): tr("key.rightShift"),
        UInt16(kVK_Option): tr("key.leftOption"), UInt16(kVK_RightOption): tr("key.rightOption")
    ]

    @objc private func clickModeChanged() { select(selection) }

    @objc private func closePanel() { close() }

    /// Runs for BOTH the 完成 button (via close()) and the title-bar close button. The controller
    /// is long-lived (owned by MenuBarManager, isReleasedWhenClosed=false), so deinit almost
    /// never fires — cleanup must happen here or the learning monitor would keep swallowing
    /// keystrokes and the timer would tick forever behind a closed window.
    func windowWillClose(_ notification: Notification) {
        stopLearning()
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

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
        drawText(tr("canvas.click"), at: NSPoint(x: padCenter.midX, y: padCenter.midY - 8), width: 70, align: .center, color: NSColor.white.withAlphaComponent(0.55), size: 11)

        // The clickpad ring's four physical direction-click buttons (dpad), each with a ring
        // zone plus an outside label. Gliding the pad is purely cursor movement — no mappings.
        addRingClick("dpadUp",    at: NSPoint(x: pad.midX, y: pad.minY + 25), arrow: "▲",
                     anchor: NSPoint(x: pad.midX, y: pad.minY), labelPoint: NSPoint(x: pad.midX, y: 15), align: .center)
        addRingClick("dpadDown",  at: NSPoint(x: pad.midX, y: pad.maxY - 25), arrow: "▼",
                     anchor: NSPoint(x: pad.midX, y: pad.maxY), labelPoint: NSPoint(x: pad.midX, y: pad.maxY + 16), align: .center)
        addRingClick("dpadLeft",  at: NSPoint(x: pad.minX + 25, y: pad.midY), arrow: "◀",
                     anchor: NSPoint(x: pad.minX, y: pad.midY), labelPoint: NSPoint(x: remote.minX - 18, y: pad.midY - 8), align: .right)
        addRingClick("dpadRight", at: NSPoint(x: pad.maxX - 25, y: pad.midY), arrow: "▶",
                     anchor: NSPoint(x: pad.maxX, y: pad.midY), labelPoint: NSPoint(x: remote.maxX + 18, y: pad.midY - 8), align: .left)

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
        drawText(tr("canvas.click"), at: NSPoint(x: center.midX, y: center.midY - 8), width: 70, align: .center, color: NSColor.white.withAlphaComponent(0.55), size: 11)
        addRingClick("dpadUp",    at: NSPoint(x: touch.midX, y: touch.minY + 25), arrow: "▲",
                     anchor: NSPoint(x: touch.midX, y: touch.minY), labelPoint: NSPoint(x: touch.midX, y: 8), align: .center)
        addRingClick("dpadDown",  at: NSPoint(x: touch.midX, y: touch.maxY - 25), arrow: "▼",
                     anchor: NSPoint(x: touch.midX, y: touch.maxY), labelPoint: NSPoint(x: touch.midX, y: touch.maxY + 8), align: .center)
        addRingClick("dpadLeft",  at: NSPoint(x: touch.minX + 25, y: touch.midY), arrow: "◀",
                     anchor: NSPoint(x: touch.minX, y: touch.midY), labelPoint: NSPoint(x: remote.minX - 18, y: touch.midY - 8), align: .right)
        addRingClick("dpadRight", at: NSPoint(x: touch.maxX - 25, y: touch.midY), arrow: "▶",
                     anchor: NSPoint(x: touch.maxX, y: touch.midY), labelPoint: NSPoint(x: remote.maxX + 18, y: touch.midY - 8), align: .left)
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
        if key == "mute", let image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: tr("button.mute")) {
            let configured = image.withSymbolConfiguration(.init(pointSize: 19, weight: .medium)) ?? image
            configured.isTemplate = true
            NSColor.white.set()
            configured.draw(in: NSRect(x: rect.midX - 12, y: rect.midY - 12, width: 24, height: 24))
        } else {
            drawText(symbol, at: NSPoint(x: rect.midX, y: rect.midY - 11), width: 46, align: .center, color: .white, size: 22)
        }
        drawLeader(from: align == .right ? NSPoint(x: rect.minX, y: rect.midY) : align == .left ? NSPoint(x: rect.maxX, y: rect.midY) : NSPoint(x: rect.midX, y: rect.maxY), to: labelPoint, selected: selected)
        drawText("\(Self.buttonName(key))\n\(mappingLabel(button: key))", at: labelPoint, width: 170, align: align, color: .labelColor, size: 13)
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
        drawText("\(Self.buttonName("siri"))\n\(mappingLabel(button: "siri"))", at: labelPoint, width: 180, align: .left, color: .labelColor, size: 13)
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
        let upPoint = NSPoint(x: remote.maxX + 20, y: rocker.minY + 18)
        let downPoint = NSPoint(x: remote.maxX + 20, y: rocker.midY + 18)
        drawLeader(from: NSPoint(x: rocker.maxX, y: rocker.minY + rocker.height * 0.25), to: upPoint, selected: selection == .button("volumeUp"))
        drawLeader(from: NSPoint(x: rocker.maxX, y: rocker.minY + rocker.height * 0.75), to: downPoint, selected: selection == .button("volumeDown"))
        drawText("\(Self.buttonName("volumeUp"))\n\(mappingLabel(button: "volumeUp"))", at: upPoint, width: 170, align: .left, color: .labelColor, size: 13)
        drawText("\(Self.buttonName("volumeDown"))\n\(mappingLabel(button: "volumeDown"))", at: downPoint, width: 170, align: .left, color: .labelColor, size: 13)
    }

    /// A quadrant of the clickpad ring — the physical direction-click button. The ring zone
    /// itself and an outside label (with leader line) both select it; the outside label shows
    /// the localized name plus the current mapping like every other button.
    private func addRingClick(_ key: String, at center: NSPoint, arrow: String,
                              anchor: NSPoint, labelPoint: NSPoint, align: NSTextAlignment) {
        let rect = NSRect(x: center.x - 30, y: center.y - 17, width: 60, height: 34)
        hitAreas.append((rect, .button(key)))
        let w: CGFloat = 190
        let hitX = align == .right ? labelPoint.x - w : align == .center ? labelPoint.x - w / 2 : labelPoint.x
        hitAreas.append((NSRect(x: hitX, y: labelPoint.y - 6, width: w, height: 34), .button(key)))

        let selected = selection == .button(key)
        if selected {
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        drawText(arrow, at: NSPoint(x: center.x, y: center.y - 8), width: 56, align: .center,
                 color: selected ? .white : NSColor.white.withAlphaComponent(0.75), size: 13)
        drawLeader(from: anchor, to: labelPoint, selected: selected)
        drawText("\(Self.buttonName(key))  \(mappingLabel(button: key))", at: labelPoint, width: 190, align: align, color: .labelColor, size: 13)
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

    /// Canvas label for an input's current mapping — resolves data-backed titles
    /// (learned shortcut / custom text / app name) rather than the generic case name.
    private func mappingLabel(button key: String) -> String {
        guard let m = manager else { return "" }
        return m.displayTitle(for: m.getMapping(for: key), target: .button(key))
    }
    static func buttonName(_ key: String) -> String {
        ["select", "menu", "tv", "siri", "playPause", "volumeUp", "volumeDown", "mute", "power",
         "dpadUp", "dpadDown", "dpadLeft", "dpadRight"].contains(key) ? tr("button.\(key)") : key
    }
}
